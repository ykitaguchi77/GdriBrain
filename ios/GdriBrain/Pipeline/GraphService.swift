import Foundation
import SwiftData

struct GraphPayload: Codable, Hashable {
    struct Node: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let source: String
        let tags: [String]
    }
    struct Edge: Codable, Hashable {
        let source: String
        let target: String
        let kind: String
        let weight: Double
    }
    let nodes: [Node]
    let edges: [Edge]
}

/// Builds the graph from the local SwiftData index. Cheap edges come from
/// Jaccard token overlap; explicit "related" edges come from a separate
/// (paid) Claude call the user can trigger from the Graph tab.
struct GraphService {
    static let shared = GraphService()
    private let anthropic: AnthropicClient

    init(anthropic: AnthropicClient = .shared) {
        self.anthropic = anthropic
    }

    func snapshot() async -> GraphPayload {
        let container = IndexStack.container
        return await Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            let notes = (try? ctx.fetch(FetchDescriptor<IndexedNote>())) ?? []
            let edges = (try? ctx.fetch(FetchDescriptor<IndexedEdge>())) ?? []

            let nodes = notes.map {
                GraphPayload.Node(id: $0.id, title: $0.title, source: $0.source, tags: $0.tags)
            }

            // Persisted edges (from "Find related" actions).
            var resultEdges = edges.map {
                GraphPayload.Edge(source: $0.sourceID, target: $0.targetID, kind: $0.kind, weight: $0.weight)
            }

            // On-the-fly Jaccard "related" edges. Cheap and re-derived each
            // time so freshly-ingested notes show up immediately.
            var tokens: [String: Set<String>] = [:]
            for n in notes {
                tokens[n.id] = Tokenize.tokens(in: n.body)
                    .union(n.keywords.map { $0.lowercased() })
                    .union(n.tags.map { $0.lowercased() })
            }
            let ids = Array(tokens.keys)
            var seen = Set<String>()
            for e in resultEdges { seen.insert("\(e.source)|\(e.target)|\(e.kind)") }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    let score = Tokenize.jaccard(tokens[a] ?? [], tokens[b] ?? [])
                    let key = "\(a)|\(b)|related"
                    if score >= 0.25, !seen.contains(key) {
                        resultEdges.append(.init(source: a, target: b, kind: "related", weight: score))
                    }
                }
            }
            return GraphPayload(nodes: nodes, edges: resultEdges)
        }.value
    }

    /// Sonnet-tier: produce a markdown summary of the selected notes.
    func summariseCluster(noteIDs: [String], usePremium: Bool) async throws -> String {
        let container = IndexStack.container
        let notes: [IndexedNote] = await Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            return (try? ctx.fetch(FetchDescriptor<IndexedNote>())) ?? []
        }.value

        let selected = notes.filter { noteIDs.contains($0.id) }
        guard !selected.isEmpty else { return "" }

        let blob = selected.map { "### \($0.title) (id=\($0.id))\n\($0.body)" }
            .joined(separator: "\n\n")
        let system = """
        You write concise markdown summaries of a user's notes. Use the same
        language as the notes. Use headings, bullets, and an "Open questions"
        section. Do not invent facts.
        """
        let tier: ModelTier = usePremium ? .premium : .default
        let user = "Summarise these notes into a single markdown document.\n\n\(blob)"
        return try await anthropic.complete(
            system: system,
            userPrompt: user,
            tier: tier,
            maxTokens: 4096
        )
    }
}
