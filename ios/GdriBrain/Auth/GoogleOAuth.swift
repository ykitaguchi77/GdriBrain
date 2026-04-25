import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google OAuth 2.0 (PKCE) for an iOS installed-app client.
///
/// Flow:
///   1. ASWebAuthenticationSession opens Google's consent page.
///   2. Google redirects to `com.ykitaguchi.gdribrain:/oauth?code=...`.
///   3. We exchange the code (with PKCE verifier) for tokens.
///   4. The refresh token lives in the iOS Keychain; access tokens are
///      minted on demand by `DriveAPI`.
///
/// Scope is `drive.file` only — we can read/write *only* files this app
/// created in the user's Drive, nothing else.
@MainActor
final class GoogleOAuth: NSObject {
    static let shared = GoogleOAuth()

    let redirectScheme = "com.ykitaguchi.gdribrain"
    var redirectURI: String { "\(redirectScheme):/oauth" }
    let scopes = ["https://www.googleapis.com/auth/drive.file", "openid", "email"]

    private var session: ASWebAuthenticationSession?
    private var pendingVerifier: String?
    private var continuation: CheckedContinuation<Void, Error>?

    var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? ""
    }

    func signIn() async throws {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        pendingVerifier = verifier

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw OAuthError.badURL }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let s = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: redirectScheme
            ) { callback, error in
                Task { @MainActor in
                    if let error {
                        self.finish(throwing: error); return
                    }
                    guard let callback else {
                        self.finish(throwing: OAuthError.noCallback); return
                    }
                    await self.handleRedirect(url: callback)
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            self.session = s
            if !s.start() { self.finish(throwing: OAuthError.sessionFailed) }
        }
    }

    func handleRedirect(url: URL) {
        Task { await handleRedirect(url: url) }
    }

    private func handleRedirect(url: URL) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            finish(throwing: OAuthError.missingCode); return
        }
        guard let verifier = pendingVerifier else {
            finish(throwing: OAuthError.missingVerifier); return
        }
        do {
            let token = try await exchangeCode(code: code, verifier: verifier)
            if let refresh = token.refreshToken {
                KeychainStore.save(.googleRefreshToken, value: refresh)
            }
            // Reset DriveAPI's in-memory token cache.
            await DriveAPI.shared.invalidateCache()
            finish()
        } catch {
            finish(throwing: error)
        }
    }

    func signOut() {
        KeychainStore.delete(.googleRefreshToken)
        KeychainStore.delete(.googleAccessTokenCache)
        Task { await DriveAPI.shared.invalidateCache() }
    }

    // MARK: - Token exchange

    private struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private func exchangeCode(code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.tokenExchange(String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private func finish(throwing error: Error? = nil) {
        session = nil
        pendingVerifier = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: ()) }
        continuation = nil
    }
}

extension GoogleOAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

enum OAuthError: LocalizedError {
    case badURL
    case noCallback
    case sessionFailed
    case missingCode
    case missingVerifier
    case tokenExchange(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid auth URL"
        case .noCallback: return "No callback from Google"
        case .sessionFailed: return "Could not start auth session"
        case .missingCode: return "Callback missing code"
        case .missingVerifier: return "PKCE verifier missing"
        case .tokenExchange(let body): return "Token exchange failed: \(body)"
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
