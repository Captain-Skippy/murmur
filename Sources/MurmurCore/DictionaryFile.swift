import Foundation

/// The personal dictionary and snippets on disk (private, in Murmur's support folder).
public enum DictionaryFile {
    struct File: Codable {
        var dictionary: PersonalDictionary
        var snippets: [Snippet]
    }

    public static func load(from url: URL = MurmurPaths.dictionary) -> (PersonalDictionary, [Snippet]) {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else {
            return (PersonalDictionary(), [])
        }
        return (f.dictionary, f.snippets)
    }

    public static func save(_ dict: PersonalDictionary, _ snippets: [Snippet], to url: URL = MurmurPaths.dictionary) throws {
        try MurmurPaths.ensurePrivate(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(File(dictionary: dict, snippets: snippets)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
