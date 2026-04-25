import Foundation

/// Drafts that haven't yet been ingested. Lives in the App Group container
/// so the Share Extension can enqueue and the main app can drain.
///
/// The Share Extension only **writes** drafts here — it does not run the
/// Anthropic / Drive pipeline (that needs the API key, which we deliberately
/// keep out of the Share Extension's reach).
final class OfflineQueue {
    static let shared = OfflineQueue()
    static let appGroup = "group.com.ykitaguchi.gdribrain"

    private let queueDir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) ?? FileManager.default.temporaryDirectory
        queueDir = base.appendingPathComponent("queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
    }

    var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: queueDir.path))?.count ?? 0
    }

    func enqueue(_ draft: Draft) throws {
        let url = queueDir.appendingPathComponent(
            "\(draft.createdAt.timeIntervalSince1970)-\(draft.id).json"
        )
        try encoder.encode(draft).write(to: url, options: .atomic)
    }

    func pending() -> [(URL, Draft)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: queueDir.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            let url = queueDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let draft = try? decoder.decode(Draft.self, from: data)
            else { return nil }
            return (url, draft)
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
