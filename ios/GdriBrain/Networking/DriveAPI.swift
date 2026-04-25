import Foundation

/// Direct Google Drive v3 REST client using the refresh token stored in the
/// iOS Keychain. The OAuth flow lives in `GoogleOAuth`; this file is purely
/// the "talk to Drive" layer.
///
/// Auth model:
///   - We store `refresh_token` long-term (Keychain).
///   - Access tokens are minted on demand via the `oauth2.googleapis.com/token`
///     endpoint with grant_type=refresh_token, cached in memory until expiry.
///   - On 401 we transparently mint a new access token and retry once.
///
/// Folder layout on Drive (matches `drive.file` scope, app-created files only):
///
///     GdriBrain/
///     ├── notes/        (one .md per note)
///     ├── attachments/  (binary uploads referenced from md)
///
/// Rationale: flat is preferable to category folders — see docs/architecture.md.
enum DriveError: LocalizedError {
    case missingRefreshToken
    case missingClientID
    case http(status: Int, body: String)
    case noFileID

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken: return "Drive not authorised — sign in with Google"
        case .missingClientID:     return "Google OAuth Client ID is not configured"
        case .http(let s, let b):  return "Drive HTTP \(s): \(b)"
        case .noFileID:            return "Drive response missing file id"
        }
    }
}

actor DriveAPI {
    static let shared = DriveAPI()

    private let driveBase = URL(string: "https://www.googleapis.com/drive/v3")!
    private let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let session: URLSession

    private var cachedAccessToken: String?
    private var cachedExpiry: Date?

    /// One-time per-launch lookup of folder IDs.
    private var rootFolderID: String?
    private var notesFolderID: String?
    private var attachmentsFolderID: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public surface

    var hasRefreshToken: Bool {
        let v = KeychainStore.load(.googleRefreshToken)
        return v != nil && !(v ?? "").isEmpty
    }

    /// Reset cached folder IDs / tokens. Useful after re-auth.
    func invalidateCache() {
        cachedAccessToken = nil
        cachedExpiry = nil
        rootFolderID = nil
        notesFolderID = nil
        attachmentsFolderID = nil
    }

    /// Upload a new markdown file or replace an existing one. Returns the
    /// Drive file id.
    func upsertMarkdown(filename: String, content: String, fileID: String? = nil) async throws -> String {
        let parent = try await ensureNotesFolder()
        let metadata: [String: Any] = ["name": filename, "parents": [parent]]
        return try await multipartUpload(
            metadata: metadata,
            data: Data(content.utf8),
            mimeType: "text/markdown",
            fileID: fileID
        )
    }

    func uploadAttachment(filename: String, data: Data, mimeType: String) async throws -> String {
        let parent = try await ensureAttachmentsFolder()
        let metadata: [String: Any] = ["name": filename, "parents": [parent]]
        return try await multipartUpload(
            metadata: metadata,
            data: data,
            mimeType: mimeType,
            fileID: nil
        )
    }

    func downloadMarkdown(fileID: String) async throws -> String {
        let url = driveBase
            .appendingPathComponent("files/\(fileID)")
            .appending(queryItems: [.init(name: "alt", value: "media")])
        let (data, _) = try await authedRequest(url: url, method: "GET")
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Folder bootstrap

    private func ensureRootFolder() async throws -> String {
        if let id = rootFolderID { return id }
        let id = try await ensureFolder(named: "GdriBrain", parent: nil)
        rootFolderID = id
        return id
    }

    private func ensureNotesFolder() async throws -> String {
        if let id = notesFolderID { return id }
        let parent = try await ensureRootFolder()
        let id = try await ensureFolder(named: "notes", parent: parent)
        notesFolderID = id
        return id
    }

    private func ensureAttachmentsFolder() async throws -> String {
        if let id = attachmentsFolderID { return id }
        let parent = try await ensureRootFolder()
        let id = try await ensureFolder(named: "attachments", parent: parent)
        attachmentsFolderID = id
        return id
    }

    private func ensureFolder(named name: String, parent: String?) async throws -> String {
        var q = "mimeType='application/vnd.google-apps.folder' and name='\(name)' and trashed=false"
        if let parent {
            q += " and '\(parent)' in parents"
        }
        let listURL = driveBase.appendingPathComponent("files").appending(queryItems: [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "1"),
        ])
        let (data, _) = try await authedRequest(url: listURL, method: "GET")
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = obj["files"] as? [[String: Any]],
           let first = files.first,
           let id = first["id"] as? String {
            return id
        }
        // Create.
        var meta: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
        ]
        if let parent { meta["parents"] = [parent] }
        let createURL = driveBase.appendingPathComponent("files").appending(queryItems: [
            .init(name: "fields", value: "id"),
        ])
        var req = URLRequest(url: createURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: meta)
        let (createdData, _) = try await sendAuthed(req)
        guard let obj = try JSONSerialization.jsonObject(with: createdData) as? [String: Any],
              let id = obj["id"] as? String
        else {
            throw DriveError.noFileID
        }
        return id
    }

    // MARK: - Multipart upload

    private func multipartUpload(
        metadata: [String: Any],
        data: Data,
        mimeType: String,
        fileID: String?
    ) async throws -> String {
        let boundary = "gdb-\(UUID().uuidString)"
        let metaData = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metaData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let path = fileID == nil ? "files" : "files/\(fileID!)"
        let url = uploadBase.appendingPathComponent(path).appending(queryItems: [
            .init(name: "uploadType", value: "multipart"),
            .init(name: "fields", value: "id"),
        ])
        var req = URLRequest(url: url)
        req.httpMethod = fileID == nil ? "POST" : "PATCH"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (respData, _) = try await sendAuthed(req)
        guard let obj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = obj["id"] as? String
        else {
            throw DriveError.noFileID
        }
        return id
    }

    // MARK: - Auth helpers

    private func authedRequest(url: URL, method: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        return try await sendAuthed(req)
    }

    private func sendAuthed(_ baseReq: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = baseReq
        let token = try await accessToken(forceRefresh: false)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw DriveError.http(status: -1, body: "no HTTP response")
        }
        if http.statusCode == 401 {
            // Stale token — refresh once and retry.
            let fresh = try await accessToken(forceRefresh: true)
            var retry = baseReq
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let (data2, resp2) = try await session.data(for: retry)
            guard let http2 = resp2 as? HTTPURLResponse else {
                throw DriveError.http(status: -1, body: "no HTTP response (retry)")
            }
            guard (200..<300).contains(http2.statusCode) else {
                throw DriveError.http(
                    status: http2.statusCode,
                    body: String(data: data2, encoding: .utf8) ?? ""
                )
            }
            return (data2, http2)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh,
           let cached = cachedAccessToken,
           let expiry = cachedExpiry,
           expiry.timeIntervalSinceNow > 30
        {
            return cached
        }
        guard let refresh = KeychainStore.load(.googleRefreshToken), !refresh.isEmpty else {
            throw DriveError.missingRefreshToken
        }
        guard let clientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String),
              !clientID.isEmpty
        else {
            throw DriveError.missingClientID
        }
        let params = [
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.http(
                status: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else {
            throw DriveError.http(status: 200, body: "missing access_token")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        cachedAccessToken = access
        cachedExpiry = Date().addingTimeInterval(expiresIn)
        return access
    }
}

private extension URL {
    func appending(queryItems items: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        var existing = comps.queryItems ?? []
        existing.append(contentsOf: items)
        comps.queryItems = existing
        return comps.url!
    }
}
