import Foundation

/// Tiered model selection. Bound to actual model IDs in `id`.
///
/// Why three tiers:
/// - `cheap` Haiku 4.5 — title / summary / keyword extraction. Sub-cent per call.
/// - `default` Sonnet 4.6 — merge decision, related notes, cluster summaries.
///   Better at JSON adherence and trade-off reasoning than Haiku.
/// - `premium` Opus 4.7 — only when the user explicitly taps "Deep analysis".
///
/// Pricing & exact IDs are pinned to the values current at the time the
/// project was scaffolded. To migrate, update the `id` map and re-run any
/// task-specific evaluations — the rest of this client is model-agnostic.
enum ModelTier: String, Codable, CaseIterable {
    case cheap
    case `default`
    case premium

    var id: String {
        switch self {
        case .cheap:    return "claude-haiku-4-5"
        case .default:  return "claude-sonnet-4-6"
        case .premium:  return "claude-opus-4-7"
        }
    }

    var displayName: String {
        switch self {
        case .cheap:    return "Haiku 4.5"
        case .default:  return "Sonnet 4.6"
        case .premium:  return "Opus 4.7"
        }
    }
}

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case noTextBlock

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Anthropic API key is not set"
        case .http(let s, let b): return "Anthropic HTTP \(s): \(b)"
        case .decoding(let s): return "Anthropic response decoding error: \(s)"
        case .noTextBlock: return "Anthropic response contained no text block"
        }
    }
}

/// Thin REST client for the Anthropic Messages API.
///
/// Notes on choices:
/// - URLSession only — there is no official Swift SDK, and a hand-rolled REST
///   client beats pulling in a community wrapper for one endpoint.
/// - We always set a `system` array of TextBlock with `cache_control:
///   ephemeral`. With Haiku 4.5 / Opus 4.7 the cache prefix needs ≥4096 tokens
///   to actually cache (≥2048 on Sonnet 4.6); our system prompts are short
///   so caching is mostly aspirational, but the marker is harmless when below
///   the threshold and useful for future longer prompts.
/// - We avoid `temperature` / `top_p` / `top_k` (removed on Opus 4.7) and
///   `budget_tokens` (deprecated/removed on the 4.6+ family). Adaptive
///   thinking is OFF by default on these models, which is what we want for
///   short structured outputs.
/// - For the `cheap` tier on Sonnet 4.6 (when invoked there) we set effort
///   `low` to avoid the new default of `high`, which would burn extra tokens
///   on a one-line summary.
actor AnthropicClient {
    static let shared = AnthropicClient()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calls the Messages API and returns the concatenated text of the
    /// response. Caller is responsible for any JSON parsing.
    func complete(
        system: String,
        userPrompt: String,
        tier: ModelTier,
        maxTokens: Int = 4096,
        jsonSchema: [String: Any]? = nil
    ) async throws -> String {
        guard let key = KeychainStore.load(.anthropicAPIKey), !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        var body: [String: Any] = [
            "model": tier.id,
            "max_tokens": maxTokens,
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "messages": [
                [
                    "role": "user",
                    "content": userPrompt,
                ],
            ],
        ]

        // Sonnet 4.6 defaults to effort:high. Dial back when we route the
        // cheap-tier work to Sonnet (rare — only if the user reconfigures).
        if tier == .cheap, tier.id == ModelTier.default.id {
            body["output_config"] = ["effort": "low"]
        }

        if let schema = jsonSchema {
            // Structured Outputs: forces a JSON response that conforms to the
            // schema. Supported on Haiku 4.5 / Sonnet 4.6 / Opus 4.7. Dropping
            // the schema for unsupported models would be a future migration.
            body["output_config"] = [
                "format": [
                    "type": "json_schema",
                    "schema": schema,
                ],
            ]
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AnthropicError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try Self.extractText(from: data)
    }

    /// Calls the API expecting JSON; returns the parsed object (Dictionary).
    func completeJSON(
        system: String,
        userPrompt: String,
        tier: ModelTier,
        maxTokens: Int = 4096,
        schema: [String: Any]
    ) async throws -> [String: Any] {
        let raw = try await complete(
            system: system,
            userPrompt: userPrompt,
            tier: tier,
            maxTokens: maxTokens,
            jsonSchema: schema
        )
        return try Self.parseJSONObject(raw)
    }

    // MARK: - Response parsing

    private static func extractText(from data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]]
        else {
            throw AnthropicError.decoding("missing content array")
        }
        let texts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        guard !texts.isEmpty else { throw AnthropicError.noTextBlock }
        return texts.joined(separator: "\n")
    }

    /// Tolerantly extract a JSON object from a model response. Even with
    /// structured outputs enabled, we still want to handle stray fences from
    /// older models or future regressions.
    private static func parseJSONObject(_ text: String) throws -> [String: Any] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceRange = trimmed.range(
            of: #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#,
            options: .regularExpression
        ) {
            trimmed = String(trimmed[fenceRange])
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        } else if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            trimmed = String(trimmed[first...last])
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AnthropicError.decoding("could not parse JSON: \(trimmed.prefix(200))")
        }
        return obj
    }
}
