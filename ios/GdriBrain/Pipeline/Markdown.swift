import Foundation

/// YAML frontmatter helpers. We don't pull in a YAML library — our schema is
/// fixed and simple (strings, ISO dates, string arrays).
enum Markdown {
    struct Frontmatter {
        var id: String
        var created: Date
        var updated: Date
        var source: String
        var title: String
        var summary: String
        var tags: [String]
        var keywords: [String]
        var url: String?
        var attachment: String?
    }

    /// Build a markdown document with YAML frontmatter on top.
    static func compose(meta: Frontmatter, body: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines: [String] = ["---"]
        lines.append("id: \(yamlScalar(meta.id))")
        lines.append("created: \(iso.string(from: meta.created))")
        lines.append("updated: \(iso.string(from: meta.updated))")
        lines.append("source: \(meta.source)")
        lines.append("title: \(yamlScalar(meta.title))")
        lines.append("summary: \(yamlScalar(meta.summary))")
        lines.append("tags: \(yamlList(meta.tags))")
        lines.append("keywords: \(yamlList(meta.keywords))")
        if let url = meta.url { lines.append("url: \(yamlScalar(url))") }
        if let att = meta.attachment { lines.append("attachment: \(yamlScalar(att))") }
        lines.append("links: []")
        lines.append("related: []")
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private static func yamlScalar(_ s: String) -> String {
        // Quote anything that contains characters YAML would interpret.
        let needsQuote = s.contains(":") || s.contains("#") || s.contains("\"")
            || s.contains("'") || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.contains("\n")
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func yamlList(_ items: [String]) -> String {
        if items.isEmpty { return "[]" }
        let parts = items.map(yamlScalar)
        return "[\(parts.joined(separator: ", "))]"
    }

    /// Best-effort slug from an arbitrary title. Falls back to the source
    /// type so filenames are always non-empty and unique-ish (the date prefix
    /// gives the rest of the uniqueness).
    static func slug(from title: String, fallback: String, max: Int = 40) -> String {
        let lowered = title.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(kept)
            .split(separator: "-")
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? fallback : trimmed
        return String(base.prefix(max))
    }

    static func newID(source: NoteSource, titleHint: String, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: now)
        let s = slug(from: titleHint, fallback: source.rawValue)
        return "\(stamp)-\(s)"
    }
}
