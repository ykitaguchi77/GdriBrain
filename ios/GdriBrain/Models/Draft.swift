import Foundation

enum NoteSource: String, Codable {
    case memo
    case link
    case screenshot
}

/// A pending input that lives in the offline queue until processed.
enum DraftPayload: Codable, Hashable {
    case memo(text: String, tags: [String])
    case link(url: String, title: String?, selectedText: String?, note: String?, tags: [String])
    case screenshot(imageBase64: String, ocrText: String?, note: String?, tags: [String])

    var source: NoteSource {
        switch self {
        case .memo: return .memo
        case .link: return .link
        case .screenshot: return .screenshot
        }
    }
}

struct Draft: Codable, Identifiable, Hashable {
    /// Used both as the queue key and as an idempotency client id.
    let id: String
    let createdAt: Date
    let payload: DraftPayload

    init(id: String = UUID().uuidString, createdAt: Date = .now, payload: DraftPayload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }
}
