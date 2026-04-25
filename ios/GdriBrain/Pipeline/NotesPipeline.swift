import Foundation
import SwiftData

/// Result of ingesting a single Draft. Mirrors what the old Python backend
/// returned so views can reuse the model.
struct IngestedNote {
    let id: String
    let driveFileID: String
    let source: NoteSource
    let title: String
    let summary: String
    let tags: [String]
    let mergedInto: String?
    let created: Date
    let updated: Date
}

/// Heart of the app. Takes a Draft, asks Claude for a title/summary, decides
/// whether it merges into an existing note, writes md to Drive, and updates
/// the local SwiftData index.
///
/// All work runs off the main actor — the UI hands a Draft over and awaits
/// the IngestedNote.
struct NotesPipeline {
    static let shared = NotesPipeline()

    private let maxCandidates = 4
    private let minSimilarity = 0.15

    private let anthropic: AnthropicClient
    private let drive: DriveAPI

    init(
        anthropic: AnthropicClient = .shared,
        drive: DriveAPI = .shared
    ) {
        self.anthropic = anthropic
        self.drive = drive
    }

    func ingest(_ draft: Draft) async throws -> IngestedNote {
        // 1. Idempotency: same client_id ⇒ already processed.
        if let existing = try await findByClientID(draft.id) {
            return existing
        }

        // 2. Build a draft body string + figure out any extra metadata.
        let (rawBody, extraURL, attachmentName, attachmentData) = try await prepareDraft(draft)

        // 3. Upload attachment first (before md) so the md can reference it.
        if let name = attachmentName, let data = attachmentData {
            _ = try await drive.uploadAttachment(filename: name, data: data, mimeType: "image/png")
        }

        // 4. Cheap-tier Claude call: title / summary / keywords / tags.
        let userTags = userProvidedTags(draft)
        let insight = try await summarise(body: rawBody, source: draft.payload.source)

        let mergedTags = Array(Set(userTags).union(insight.tags)).sorted()
        let allTokens = Tokenize.tokens(in: rawBody)
            .union(insight.keywords.map { $0.lowercased() })
            .union(mergedTags.map { $0.lowercased() })

        // 5. Find merge candidates locally; if any, ask Sonnet to decide.
        let candidates = try await pickCandidates(tokens: allTokens)
        if !candidates.isEmpty,
           let decision = try? await decideMerge(newBody: rawBody, candidates: candidates),
           decision.shouldMerge,
           let targetID = decision.targetID,
           let mergedBody = decision.mergedMarkdown,
           let target = candidates.first(where: { $0.id == targetID })
        {
            return try await applyMerge(
                target: target,
                mergedBody: mergedBody,
                addedTags: mergedTags,
                addedKeywords: insight.keywords,
                clientID: draft.id
            )
        }

        // 6. New note path.
        return try await persistNew(
            source: draft.payload.source,
            rawBody: rawBody,
            insight: insight,
            tags: mergedTags,
            extraURL: extraURL,
            attachmentName: attachmentName,
            clientID: draft.id
        )
    }

    // MARK: - Draft → body

    private func userProvidedTags(_ draft: Draft) -> [String] {
        switch draft.payload {
        case .memo(_, let tags),
             .link(_, _, _, _, let tags),
             .screenshot(_, _, _, let tags):
            return tags
        }
    }

    private func prepareDraft(_ draft: Draft) async throws -> (
        body: String,
        url: String?,
        attachmentName: String?,
        attachmentData: Data?
    ) {
        switch draft.payload {
        case .memo(let text, _):
            return (text, nil, nil, nil)
        case .link(let url, let title, let selectedText, let note, _):
            var lines: [String] = []
            lines.append("# \(title ?? url)")
            lines.append("")
            lines.append("<\(url)>")
            lines.append("")
            if let s = selectedText {
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
                }
                lines.append("")
            }
            if let n = note { lines.append(n); lines.append("") }
            return (
                lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                url, nil, nil
            )
        case .screenshot(let imageBase64, let ocrText, let note, _):
            guard let data = Data(base64Encoded: imageBase64) else {
                throw PipelineError.invalidScreenshotData
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let attachment = "\(formatter.string(from: .now)).png"
            var lines: [String] = ["# Screenshot"]
            if let ocr = ocrText, !ocr.isEmpty {
                lines.append("")
                lines.append("## OCR")
                lines.append(ocr)
            }
            if let n = note, !n.isEmpty {
                lines.append("")
                lines.append("## Note")
                lines.append(n)
            }
            lines.append("")
            lines.append("[attachment](\(attachment))")
            return (
                lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                nil, attachment, data
            )
        }
    }

    // MARK: - Claude calls

    private struct Insight {
        let title: String
        let summary: String
        let keywords: [String]
        let tags: [String]
    }

    private func summarise(body: String, source: NoteSource) async throws -> Insight {
        let system = """
        You are an assistant inside a personal knowledge system (GdriBrain).
        You produce short, accurate JSON descriptions of the user's notes.
        Always respond in the same language as the note.
        """
        let user = """
        The following is a new note of type `\(source.rawValue)`. Return JSON
        matching the schema. Title <= 60 chars. Summary <= 160 chars (one
        sentence). Keywords: 3-8 lowercase strings. Tags: 0-4 high-level
        category tags.

        NOTE:
        \(body)
        """
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title":    ["type": "string"],
                "summary":  ["type": "string"],
                "keywords": ["type": "array", "items": ["type": "string"]],
                "tags":     ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["title", "summary", "keywords", "tags"],
        ]
        let obj = try await anthropic.completeJSON(
            system: system,
            userPrompt: user,
            tier: .cheap,
            maxTokens: 1024,
            schema: schema
        )
        return Insight(
            title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled",
            summary: (obj["summary"] as? String) ?? "",
            keywords: (obj["keywords"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty },
            tags: (obj["tags"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        )
    }

    private struct Candidate {
        let id: String
        let driveFileID: String
        let title: String
        let body: String
        let tags: [String]
        let keywords: [String]
        let summary: String
    }

    private struct MergeDecision {
        let shouldMerge: Bool
        let targetID: String?
        let mergedMarkdown: String?
        let reason: String
    }

    private func decideMerge(newBody: String, candidates: [Candidate]) async throws -> MergeDecision {
        let system = """
        You decide whether a new note should be merged into one of several
        existing notes (same topic, just adding/updating detail) or kept as a
        standalone new note. When merging, you write the full updated body for
        the merged note (without YAML frontmatter), preserving all existing
        detail and integrating the new content. Match the user's language.
        """
        let candidateBlocks = candidates.map { c -> String in
            "=== CANDIDATE id=\(c.id) title=\(c.title) ===\n\(c.body)"
        }.joined(separator: "\n\n")
        let user = """
        NEW NOTE:
        \(newBody)

        \(candidateBlocks)
        """
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "should_merge":    ["type": "boolean"],
                "target_id":       ["type": ["string", "null"]],
                "merged_markdown": ["type": ["string", "null"]],
                "reason":          ["type": "string"],
            ],
            "required": ["should_merge", "target_id", "merged_markdown", "reason"],
        ]
        let obj = try await anthropic.completeJSON(
            system: system,
            userPrompt: user,
            tier: .default,
            maxTokens: 8192,
            schema: schema
        )
        return MergeDecision(
            shouldMerge: (obj["should_merge"] as? Bool) ?? false,
            targetID: obj["target_id"] as? String,
            mergedMarkdown: obj["merged_markdown"] as? String,
            reason: (obj["reason"] as? String) ?? ""
        )
    }

    // MARK: - Local index

    private func findByClientID(_ clientID: String) async throws -> IngestedNote? {
        try await onIndex { ctx in
            var fetch = FetchDescriptor<IndexedNote>(
                predicate: #Predicate { $0.clientID == clientID }
            )
            fetch.fetchLimit = 1
            guard let row = try ctx.fetch(fetch).first else { return nil }
            return row.toIngested(mergedInto: nil)
        }
    }

    private func pickCandidates(tokens: Set<String>) async throws -> [Candidate] {
        try await onIndex { ctx in
            let rows = try ctx.fetch(FetchDescriptor<IndexedNote>())
            var scored: [(Double, Candidate)] = []
            for row in rows {
                let existing = Tokenize.tokens(in: row.body)
                    .union(row.keywords.map { $0.lowercased() })
                    .union(row.tags.map { $0.lowercased() })
                let score = Tokenize.jaccard(tokens, existing)
                guard score >= self.minSimilarity else { continue }
                scored.append((score, Candidate(
                    id: row.id,
                    driveFileID: row.driveFileID,
                    title: row.title,
                    body: row.body,
                    tags: row.tags,
                    keywords: row.keywords,
                    summary: row.summary
                )))
            }
            return scored.sorted { $0.0 > $1.0 }.prefix(self.maxCandidates).map { $0.1 }
        }
    }

    private func persistNew(
        source: NoteSource,
        rawBody: String,
        insight: Insight,
        tags: [String],
        extraURL: String?,
        attachmentName: String?,
        clientID: String
    ) async throws -> IngestedNote {
        let now = Date()
        let id = Markdown.newID(source: source, titleHint: insight.title, now: now)
        let meta = Markdown.Frontmatter(
            id: id,
            created: now,
            updated: now,
            source: source.rawValue,
            title: insight.title,
            summary: insight.summary,
            tags: tags,
            keywords: insight.keywords,
            url: extraURL,
            attachment: attachmentName
        )
        let md = Markdown.compose(meta: meta, body: rawBody)
        let driveID = try await drive.upsertMarkdown(
            filename: "\(id).md",
            content: md
        )
        try await onIndex { ctx in
            let row = IndexedNote(
                id: id,
                driveFileID: driveID,
                source: source.rawValue,
                title: insight.title,
                summary: insight.summary,
                tags: tags,
                keywords: insight.keywords,
                body: rawBody,
                created: now,
                updated: now,
                clientID: clientID
            )
            ctx.insert(row)
            try ctx.save()
        }
        return IngestedNote(
            id: id,
            driveFileID: driveID,
            source: source,
            title: insight.title,
            summary: insight.summary,
            tags: tags,
            mergedInto: nil,
            created: now,
            updated: now
        )
    }

    private func applyMerge(
        target: Candidate,
        mergedBody: String,
        addedTags: [String],
        addedKeywords: [String],
        clientID: String
    ) async throws -> IngestedNote {
        let now = Date()
        let mergedTags = Array(Set(target.tags).union(addedTags)).sorted()
        let mergedKeywords = Array(Set(target.keywords).union(addedKeywords)).sorted()

        // We need original `created` and `summary` for the rewritten md.
        let original = try await onIndex { ctx -> IndexedNote? in
            var fetch = FetchDescriptor<IndexedNote>(
                predicate: #Predicate { $0.id == target.id }
            )
            fetch.fetchLimit = 1
            return try ctx.fetch(fetch).first
        }
        guard let original else {
            throw PipelineError.mergeTargetMissing(id: target.id)
        }

        let meta = Markdown.Frontmatter(
            id: original.id,
            created: original.created,
            updated: now,
            source: original.source,
            title: original.title,
            summary: original.summary,
            tags: mergedTags,
            keywords: mergedKeywords,
            url: nil,
            attachment: nil
        )
        let md = Markdown.compose(meta: meta, body: mergedBody)
        _ = try await drive.upsertMarkdown(
            filename: "\(original.id).md",
            content: md,
            fileID: original.driveFileID
        )

        try await onIndex { ctx in
            var fetch = FetchDescriptor<IndexedNote>(
                predicate: #Predicate { $0.id == target.id }
            )
            fetch.fetchLimit = 1
            guard let row = try ctx.fetch(fetch).first else { return }
            row.body = mergedBody
            row.tags = mergedTags
            row.keywords = mergedKeywords
            row.updated = now
            row.clientID = clientID
            try ctx.save()
        }
        return IngestedNote(
            id: original.id,
            driveFileID: original.driveFileID,
            source: NoteSource(rawValue: original.source) ?? .memo,
            title: original.title,
            summary: original.summary,
            tags: mergedTags,
            mergedInto: original.id,
            created: original.created,
            updated: now
        )
    }

    private func onIndex<T>(_ work: @Sendable @escaping (ModelContext) throws -> T) async throws -> T {
        let container = IndexStack.container
        return try await Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            return try work(ctx)
        }.value
    }
}

enum PipelineError: LocalizedError {
    case invalidScreenshotData
    case mergeTargetMissing(id: String)

    var errorDescription: String? {
        switch self {
        case .invalidScreenshotData: return "Screenshot image data is not valid"
        case .mergeTargetMissing(let id): return "Merge target \(id) not found"
        }
    }
}

private extension IndexedNote {
    func toIngested(mergedInto: String?) -> IngestedNote {
        IngestedNote(
            id: id,
            driveFileID: driveFileID,
            source: NoteSource(rawValue: source) ?? .memo,
            title: title,
            summary: summary,
            tags: tags,
            mergedInto: mergedInto,
            created: created,
            updated: updated
        )
    }
}
