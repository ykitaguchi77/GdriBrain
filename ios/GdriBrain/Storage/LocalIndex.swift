import Foundation
import SwiftData

/// SwiftData-backed local cache of notes (Drive remains the source of truth).
///
/// Why SwiftData:
/// - Built into iOS 17+ — zero external dependencies
/// - Enough for our use cases (similarity scan, list, search)
/// - Easy to inspect with Xcode preview / debugger
///
/// Drive holds the markdown; we keep enough metadata + body here to:
///   1. Pick merge candidates by token overlap without round-tripping Drive
///   2. Render Notes / Graph tabs offline
///   3. De-dup the offline queue via `clientID`
@Model
final class IndexedNote {
    @Attribute(.unique) var id: String
    var driveFileID: String
    var source: String       // "memo" | "link" | "screenshot"
    var title: String
    var summary: String
    var tagsJSON: String     // ["tag1","tag2"] encoded as JSON
    var keywordsJSON: String
    var body: String
    var created: Date
    var updated: Date
    var clientID: String?

    init(
        id: String,
        driveFileID: String,
        source: String,
        title: String,
        summary: String,
        tags: [String],
        keywords: [String],
        body: String,
        created: Date,
        updated: Date,
        clientID: String? = nil
    ) {
        self.id = id
        self.driveFileID = driveFileID
        self.source = source
        self.title = title
        self.summary = summary
        self.tagsJSON = Self.encodeStrings(tags)
        self.keywordsJSON = Self.encodeStrings(keywords)
        self.body = body
        self.created = created
        self.updated = updated
        self.clientID = clientID
    }

    var tags: [String] {
        get { Self.decodeStrings(tagsJSON) }
        set { tagsJSON = Self.encodeStrings(newValue) }
    }

    var keywords: [String] {
        get { Self.decodeStrings(keywordsJSON) }
        set { keywordsJSON = Self.encodeStrings(newValue) }
    }

    static func encodeStrings(_ strings: [String]) -> String {
        guard let data = try? JSONEncoder().encode(strings),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    static func decodeStrings(_ s: String) -> [String] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }
}

@Model
final class IndexedEdge {
    var sourceID: String
    var targetID: String
    var kind: String     // "related"
    var weight: Double

    init(sourceID: String, targetID: String, kind: String, weight: Double) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.weight = weight
    }
}

/// Process-wide handle. SwiftUI `@Environment(\.modelContext)` is fine for
/// views, but the ingestion pipeline runs off the main actor and needs its
/// own background context.
enum IndexStack {
    static let schema = Schema([IndexedNote.self, IndexedEdge.self])

    static let container: ModelContainer = {
        do {
            let config = ModelConfiguration(
                "GdriBrainIndex",
                schema: schema,
                isStoredInMemoryOnly: false
            )
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer init failed: \(error)")
        }
    }()
}
