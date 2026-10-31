import Foundation

/// Unambiguous spoken formatting, applied to the transcript before the cleanup model:
/// identifiers ("load underscore models"), flags ("dash dash limit"), file extensions
/// ("controller dot swift"), slashes, emails ("sam at example.com") and a leading "Bullets".
/// The model handles everything that needs judgment (self-corrections, "new line" as a
/// command or as words, lists without a spoken cue).
public enum SpokenFormat {
    static let extensions = ["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "yaml", "yml", "toml", "sh", "txt",
                             "html", "css", "rs", "go", "c", "h", "cpp", "java", "kt", "rb", "sql", "csv", "pdf",
                             "com", "org", "net", "io", "edu", "dev", "app", "ai", "me", "gov", "co"]

    public static func apply(_ text: String, style: AppStyle) -> String {
        var s = text
        s = identifiers(s)
        s = replace(s, #"(?i)\bdash dash (?=[A-Za-z])"#, "--")
        if style == .code || style == .terminal {
            // "bench dash ASR" -> "bench-ASR", "parakeet dash v2" -> "parakeet-v2".
            s = replace(s, #"(?i)(?<=[A-Za-z0-9])[ ,]+dash[ ,]+(?=[A-Za-z0-9])"#, "-")
        }
        let ext = extensions.joined(separator: "|")
        s = replace(s, #"(?i)(?<=[A-Za-z0-9_])[ ,]+dot[ ,]+(?=(?:"# + ext + #")\b)"#, ".")
        s = replace(s, #"(?i)(?<=[A-Za-z0-9_.])[ ,]+slash[ ,]+(?=[A-Za-z0-9_.])"#, "/")
        // Email: a token without spaces, "at", a domain.
        s = replace(s, #"(?i)\b([A-Za-z0-9._%+-]+)\s+at\s+([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|io|edu|dev|me|gov|co|ai)\b)"#, "$1@$2")
        s = bullets(s)
        return s
    }

    /// "murmur underscore sign underscore identity all caps" -> MURMUR_SIGN_IDENTITY.
    static func identifiers(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b([A-Za-z0-9]+)((?:[ ,]+underscore[ ,]+[A-Za-z0-9]+)+)(,? all caps)?"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out), let first = Range(m.range(at: 1), in: out), let rest = Range(m.range(at: 2), in: out) else { continue }
            let parts = [String(out[first])] + out[rest].components(separatedBy: CharacterSet(charactersIn: " ,"))
                .filter { !$0.isEmpty && $0.lowercased() != "underscore" }
            let caps = m.range(at: 3).location != NSNotFound
            let id = parts.map { caps ? $0.uppercased() : $0.lowercased() }.joined(separator: "_")
            out.replaceSubrange(r, with: id)
        }
        return out
    }

    /// A transcript that starts with "Bullets" / "Bullet points" / "As a list" becomes a list.
    static func bullets(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"^\s*(?i:bullets|bullet points|as a list)\s*[.:,]\s+(.+)$"#, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let body = Range(m.range(at: 1), in: s) else { return s }
        var text = String(s[body]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = text.last, ".!".contains(l) { text.removeLast() }
        let items = text.replacingOccurrences(of: #",?\s+and\s+(?=[^,]+$)"#, with: ", ", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard items.count >= 2 else { return s }
        return items.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "\n")
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
