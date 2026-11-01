import Foundation

/// One thing a spoken command does to the desktop. The set is small and closed on purpose:
/// nothing here runs a script, deletes a file or reaches past the frontmost app's own UI.
public enum ControlAction: Equatable, Sendable {
    /// Open or bring forward an app, by the display name it was resolved to.
    case openApp(String)
    /// Quit an app; nil quits the frontmost one.
    case quitApp(String?)
    case openURL(String)
    /// A folder under the home directory, "~/Downloads".
    case openFolder(String)
    case search(String, site: SearchSite)
    case keys(KeyChord)
    /// Find a control in the frontmost window by its title or label and press it.
    case click(String)
    /// Type into the focused field.
    case type(String)
    /// Cmd+F, then the text.
    case findInPage(String)
    case scroll(ScrollDirection)

    /// What the indicator says while it happens.
    public var summary: String {
        switch self {
        case .openApp(let n): "Opening \(n)"
        case .quitApp(let n): n.map { "Quitting \($0)" } ?? "Quitting"
        case .openURL(let u): "Opening " + u.replacingOccurrences(of: "https://", with: "")
        case .openFolder(let f): "Opening " + (f.split(separator: "/").last.map(String.init) ?? f)
        case .search(let q, let site): site == .web ? "Searching \u{201C}\(q)\u{201D}" : "Searching \(site.label) for \u{201C}\(q)\u{201D}"
        case .keys(let k): k.label
        case .click(let t): "Clicking \u{201C}\(t)\u{201D}"
        case .type(let t): "Typing \u{201C}\(t.prefix(30))\u{201D}"
        case .findInPage(let t): "Finding \u{201C}\(t)\u{201D}"
        case .scroll(let d): "Scrolling \(d.rawValue)"
        }
    }
}

public enum ScrollDirection: String, Sendable, Equatable { case up, down, left, right }

public enum SearchSite: String, Sendable, Equatable, CaseIterable {
    case web, images, youtube, amazon, wikipedia, maps, directions, github, reddit

    public var label: String {
        switch self {
        case .web: "the web"
        case .images: "images"
        case .youtube: "YouTube"
        case .amazon: "Amazon"
        case .wikipedia: "Wikipedia"
        case .maps, .directions: "Maps"
        case .github: "GitHub"
        case .reddit: "Reddit"
        }
    }

    public func url(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        switch self {
        case .web: return "https://www.google.com/search?q=" + q
        case .images: return "https://www.google.com/search?tbm=isch&q=" + q
        case .youtube: return "https://www.youtube.com/results?search_query=" + q
        case .amazon: return "https://www.amazon.com/s?k=" + q
        case .wikipedia: return "https://en.wikipedia.org/w/index.php?search=" + q
        case .maps: return "https://www.google.com/maps/search/?api=1&query=" + q
        case .directions: return "https://www.google.com/maps/dir/?api=1&destination=" + q
        case .github: return "https://github.com/search?q=" + q
        case .reddit: return "https://www.reddit.com/search/?q=" + q
        }
    }

    /// The site named after "on" or "in" ("search cats on youtube").
    static func named(_ words: [String]) -> SearchSite? {
        switch words.joined(separator: " ") {
        case "google", "the web", "the internet", "the web browser", "web": .web
        case "google images", "images": .images
        case "youtube": .youtube
        case "amazon": .amazon
        case "wikipedia", "wiki": .wikipedia
        case "maps", "google maps", "the map", "a map": .maps
        case "github": .github
        case "reddit": .reddit
        default: nil
        }
    }
}

/// A key with modifiers, by name, so the app maps it to the current keyboard layout.
public struct KeyChord: Equatable, Sendable {
    /// A single character ("t", "1", "[") or a named key: return, escape, tab, space, delete,
    /// forwarddelete, up, down, left, right, pageup, pagedown, home, end, f1...f12.
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public var label: String {
        var s = ""
        if control { s += "\u{2303}" }
        if option { s += "\u{2325}" }
        if shift { s += "\u{21E7}" }
        if command { s += "\u{2318}" }
        let names = ["return": "\u{21A9}", "escape": "esc", "tab": "\u{21E5}", "space": "space", "delete": "\u{232B}",
                     "forwarddelete": "\u{2326}", "up": "\u{2191}", "down": "\u{2193}", "left": "\u{2190}", "right": "\u{2192}",
                     "pageup": "page up", "pagedown": "page down", "home": "home", "end": "end"]
        return s + (names[key] ?? key.uppercased())
    }

    static let named: Set<String> = ["return", "escape", "tab", "space", "delete", "forwarddelete", "up", "down", "left",
                                     "right", "pageup", "pagedown", "home", "end"]
}

/// The result of reading one utterance as a command.
public enum ControlParse: Equatable, Sendable {
    case actions([ControlAction])
    /// A verb without its object ("search for", "open"): more speech is probably coming.
    case incomplete
    /// Not a phrasing the parser knows; a model may still make sense of it.
    case unknown
}

/// Words of an utterance, each lowercased and stripped of surrounding punctuation, next to
/// the word as spoken (for typing text with its capitals).
struct Utterance {
    var words: [String]
    var raws: [String]

    init(_ text: String) {
        var w: [String] = [], r: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let raw = String(token)
            let edge = CharacterSet(charactersIn: ".,!?;:\"\u{201C}\u{201D}()[]{}")
            let word = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .trimmingCharacters(in: edge)
            guard !word.isEmpty else { continue }
            w.append(word)
            r.append(raw)
        }
        words = w
        raws = r
    }

    init(words: [String], raws: [String]) {
        self.words = words
        self.raws = raws
    }

    var isEmpty: Bool { words.isEmpty }
    var text: String { words.joined(separator: " ") }
    /// The words as spoken, minus a period the recognizer added at the end.
    var rawText: String {
        var s = raws.joined(separator: " ")
        if s.hasSuffix(".") && !s.hasSuffix("..") { s.removeLast() }
        return s
    }

    func slice(_ r: Range<Int>) -> Utterance {
        Utterance(words: Array(words[r]), raws: Array(raws[r]))
    }

    func dropFirst(_ n: Int) -> Utterance { slice(min(n, words.count)..<words.count) }
    func dropLast(_ n: Int) -> Utterance { slice(0..<max(words.count - n, 0)) }

    func starts(with phrase: [String]) -> Bool {
        words.count >= phrase.count && Array(words[0..<phrase.count]) == phrase
    }

    func ends(with phrase: [String]) -> Bool {
        words.count >= phrase.count && Array(words.suffix(phrase.count)) == phrase
    }

    /// The first of `phrases` the utterance starts with, longest first.
    func prefix(among phrases: [[String]]) -> [String]? {
        phrases.sorted { $0.count > $1.count }.first { starts(with: $0) }
    }

    /// Drop leading words like "the", "my", "a".
    func droppingArticles() -> Utterance {
        var u = self
        while let f = u.words.first, ["the", "my", "a", "an", "this", "that"].contains(f), u.words.count > 1 { u = u.dropFirst(1) }
        return u
    }
}

/// Reads common spoken commands without a model, so the action starts the moment the words
/// are known. Anything it does not recognize comes back `.unknown` for a model to try.
public struct ControlParser: Sendable {
    /// Display names of installed apps ("Google Chrome", "Visual Studio Code").
    public var apps: [String]

    public init(apps: [String]) { self.apps = apps }

    public func parse(_ text: String) -> ControlParse {
        let u = Self.stripFillers(Utterance(text))
        if u.isEmpty { return .unknown }
        if let (actions, _) = parseSequence(u) { return .actions(actions) }
        if case .incomplete = single(u) { return .incomplete }
        return .unknown
    }

    // MARK: Fillers

    static let leading: [[String]] = [
        "um", "uh", "uhm", "hmm", "okay", "ok", "so", "hey", "please", "can you", "could you", "would you", "will you",
        "i want to", "i wanna", "i'd like to", "i need to", "let's", "lets", "go ahead and", "now", "and", "then", "and then",
        "also", "alright", "all right", "murmur", "computer",
    ].map { $0.split(separator: " ").map(String.init) }
    static let trailing: [[String]] = ["please", "for me", "now", "thanks", "thank you", "real quick"]
        .map { $0.split(separator: " ").map(String.init) }

    static func stripFillers(_ input: Utterance) -> Utterance {
        var u = input
        var changed = true
        while changed && !u.isEmpty {
            changed = false
            if let p = u.prefix(among: leading), u.words.count > p.count { u = u.dropFirst(p.count); changed = true }
            for p in trailing where u.words.count > p.count && u.ends(with: p) { u = u.dropLast(p.count); changed = true }
        }
        return u
    }

    // MARK: Sequences

    /// "open safari and then new tab": split at "and", "then", "and then" only when both sides
    /// are confident commands; otherwise the whole is one command ("search for salt and pepper").
    func parseSequence(_ u: Utterance) -> ([ControlAction], Bool)? {
        for i in 1..<max(u.words.count, 1) {
            let w = u.words[i]
            guard w == "and" || w == "then" else { continue }
            var skip = 1
            if w == "and", i + 1 < u.words.count, u.words[i + 1] == "then" { skip = 2 }
            let left = Self.stripFillers(u.slice(0..<i))
            let right = Self.stripFillers(u.dropFirst(i + skip))
            guard !left.isEmpty, !right.isEmpty else { continue }
            guard case .action(let a, true) = single(left), let rest = parseSequence(right), rest.1 else { continue }
            return ([a] + rest.0, true)
        }
        if case .action(let a, let confident) = single(u) { return ([a], confident) }
        return nil
    }

    enum Single: Equatable {
        case action(ControlAction, Bool)
        case incomplete
        case none
    }

    // MARK: One command

    func single(_ u: Utterance) -> Single {
        let text = u.text
        if let a = Self.phrases[text] { return .action(a, true) }
        let bare = u.droppingArticles()
        if let a = Self.phrases[bare.text] { return .action(a, true) }

        // Keys: "press command shift t", "hit enter". A name that is not a key is a button: "press submit".
        if let verb = u.prefix(among: [["press"], ["hit"], ["push"]]) {
            let rest = u.dropFirst(verb.count).droppingArticles()
            if rest.isEmpty { return .incomplete }
            let keyWords = rest.words.flatMap { w in
                w.count > 1 && (w.contains("-") || w.contains("+")) ? w.split(whereSeparator: { $0 == "-" || $0 == "+" }).map(String.init) : [w]
            }
            if let chord = Self.chord(keyWords) { return .action(.keys(chord), true) }
            return .action(.click(Self.controlName(rest)), true)
        }
        if let verb = u.prefix(among: [["click"], ["click", "on"], ["tap"], ["tap", "on"], ["double", "click"]]) {
            let rest = u.dropFirst(verb.count).droppingArticles()
            if rest.isEmpty { return .incomplete }
            return .action(.click(Self.controlName(rest)), true)
        }
        if let verb = u.prefix(among: [["type"], ["write"], ["type", "out"]]) {
            let rest = u.dropFirst(verb.count)
            if rest.isEmpty { return .incomplete }
            return .action(.type(rest.rawText), true)
        }
        if let verb = u.prefix(among: [["scroll"]]) {
            let rest = u.dropFirst(verb.count).droppingArticles()
            switch rest.text {
            case "", "down", "down a bit", "down some", "a bit", "more": return .action(.scroll(.down), true)
            case "up", "up a bit", "back up": return .action(.scroll(.up), true)
            case "left": return .action(.scroll(.left), true)
            case "right": return .action(.scroll(.right), true)
            case "to top", "to the top", "all the way up": return .action(.keys(KeyChord("up", command: true)), true)
            case "to bottom", "to the bottom", "all the way down": return .action(.keys(KeyChord("down", command: true)), true)
            default: return .none
            }
        }
        if let s = search(u) { return s }
        if u.words.count >= 3, Self.questionWords.contains(u.words[0]) {
            return .action(.search(u.text, site: .web), true)
        }
        if let verb = u.prefix(among: [["quit"], ["close"], ["exit"], ["kill"], ["force", "quit"]]) {
            let rest = u.dropFirst(verb.count).droppingArticles()
            if rest.isEmpty { return verb == ["close"] ? .action(.keys(KeyChord("w", command: true)), true) : .action(.quitApp(nil), true) }
            if ["app", "it", "this app", "application", "the app"].contains(rest.text) { return .action(.quitApp(nil), true) }
            let target = Self.trimAppWord(rest)
            if let m = AppMatcher.match(target.text, among: apps), m.strength >= .fuzzy { return .action(.quitApp(m.name), m.strength > .fuzzy) }
            return .none
        }
        if let verb = u.prefix(among: Self.openVerbs) {
            let rest = u.dropFirst(verb.count).droppingArticles()
            if rest.isEmpty { return .incomplete }
            return open(rest)
        }
        return .none
    }

    static let questionWords: Set<String> = ["what", "what's", "whats", "who", "who's", "when", "when's", "where", "where's",
                                             "why", "how", "how's", "which", "is", "are", "does", "do", "did", "can", "should"]

    static let openVerbs: [[String]] = ["open", "open up", "launch", "start", "switch to", "go to", "bring up", "pull up",
                                        "show me", "show", "fire up", "navigate to", "visit", "take me to", "get me"]
        .map { $0.split(separator: " ").map(String.init) }

    /// "go to github dot com", "open spotify", "open downloads".
    func open(_ target: Utterance) -> Single {
        let t = Self.trimAppWord(target)
        let name = t.text
        if let folder = Self.folders[name] { return .action(.openFolder(folder), true) }
        // An installed app by its exact name wins; a site's name beats a partial app name
        // ("google" is google.com, not Google Chrome).
        let match = AppMatcher.match(name, among: apps)
        if let m = match, m.strength == .exact { return .action(.openApp(m.name), true) }
        if let url = Self.url(from: t.words) { return .action(.openURL(url), true) }
        if let site = Self.sites[name] { return .action(.openURL(site), true) }
        if let m = match { return .action(.openApp(m.name), true) }
        if let (q, site) = Self.splitSite(t) { return .action(.search(q, site: site), true) }
        // Unknown: a web search is a safe guess, but not confident enough to chain on.
        return .action(.search(name, site: .web), false)
    }

    /// "search for X", "search youtube for X", "look up X on amazon", "google X", "directions to X".
    func search(_ u: Utterance) -> Single? {
        if let verb = u.prefix(among: [["directions", "to"], ["get", "directions", "to"], ["how", "do", "i", "get", "to"]]) {
            let rest = u.dropFirst(verb.count)
            return rest.isEmpty ? .incomplete : .action(.search(rest.text, site: .directions), true)
        }
        if let verb = u.prefix(among: [["play"]]) {
            // Only "play X on youtube": a bare "play" is media, which this does not handle.
            let rest = u.dropFirst(verb.count)
            if let (q, site) = Self.splitSite(rest), site == .youtube { return .action(.search(q, site: .youtube), true) }
            return nil
        }
        let verbs: [[String]] = [["search"], ["search", "for"], ["search", "up"], ["look", "up"], ["look", "for"], ["google"],
                                 ["search", "the", "web", "for"], ["search", "online", "for"], ["find"], ["find", "me"]]
        guard let verb = u.prefix(among: verbs) else {
            // "youtube cats"
            if u.words.count > 1, let site = SearchSite.named([u.words[0]]), site == .youtube {
                return .action(.search(u.dropFirst(1).text, site: site), true)
            }
            return nil
        }
        var rest = u.dropFirst(verb.count)
        if rest.isEmpty { return .incomplete }
        // "search youtube for cats", "search on youtube for cats"
        if verb == ["search"] || verb == ["google"] {
            var r = rest
            if r.starts(with: ["on"]) || r.starts(with: ["in"]) { r = r.dropFirst(1) }
            for n in [2, 1] where r.words.count > n {
                if let site = SearchSite.named(Array(r.words[0..<n])) {
                    var q = r.dropFirst(n)
                    if q.starts(with: ["for"]) { q = q.dropFirst(1) }
                    if q.isEmpty { return .incomplete }
                    return .action(.search(q.text, site: site), true)
                }
            }
        }
        if let (q, site) = Self.splitSite(rest) { return .action(.search(q, site: site), true) }
        if verb == ["find"] {
            // "find X" alone is find in this page; "find X on amazon" was handled above.
            return .action(.findInPage(rest.rawText), true)
        }
        if rest.starts(with: ["for"]) { rest = rest.dropFirst(1) }
        if rest.isEmpty { return .incomplete }
        return .action(.search(rest.text, site: .web), true)
    }

    /// "cats on youtube" -> ("cats", .youtube)
    static func splitSite(_ u: Utterance) -> (String, SearchSite)? {
        for i in stride(from: u.words.count - 2, through: 1, by: -1) where ["on", "in", "using"].contains(u.words[i]) {
            let site = Array(u.words[(i + 1)...])
            if let s = SearchSite.named(site) {
                let q = u.slice(0..<i)
                var qq = q
                if qq.starts(with: ["for"]) { qq = qq.dropFirst(1) }
                if !qq.isEmpty { return (qq.text, s) }
            }
        }
        return nil
    }

    static func trimAppWord(_ u: Utterance) -> Utterance {
        var t = u
        for w in [["app"], ["application"], ["website"], ["site"], ["window"], ["folder"]] where t.words.count > 1 && t.ends(with: w) {
            t = t.dropLast(1)
        }
        return t
    }

    /// The name of a button to click, minus "button" or "link" at the end.
    static func controlName(_ u: Utterance) -> String {
        var t = u
        for w in ["button", "link", "tab", "menu", "icon", "checkbox"] where t.words.count > 1 && t.ends(with: [w]) { t = t.dropLast(1) }
        return t.rawText.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"\u{201C}\u{201D}"))
    }

    /// "github dot com", "github.com", "docs.google.com/x" -> https URL.
    static func url(from words: [String]) -> String? {
        var joined = words.joined(separator: " ")
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " slash ", with: "/")
        if joined.hasPrefix("https://") || joined.hasPrefix("http://") { return joined.contains(" ") ? nil : joined }
        // "github .com" from recognizers that space the dot.
        joined = joined.replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: ". ", with: ".")
        guard !joined.contains(" ") else { return nil }
        let host = joined.split(separator: "/").first.map(String.init) ?? joined
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return "https://" + joined
    }

    // MARK: Tables

    static let folders: [String: String] = [
        "downloads": "~/Downloads", "download": "~/Downloads", "documents": "~/Documents", "desktop": "~/Desktop",
        "home": "~", "home folder": "~", "pictures": "~/Pictures", "music folder": "~/Music", "movies": "~/Movies",
        "applications": "/Applications", "applications folder": "/Applications",
    ]

    static let sites: [String: String] = [
        "google": "https://www.google.com", "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com",
        "google drive": "https://drive.google.com", "drive": "https://drive.google.com", "google docs": "https://docs.google.com",
        "google sheets": "https://sheets.google.com", "google calendar": "https://calendar.google.com",
        "google maps": "https://maps.google.com", "github": "https://github.com", "reddit": "https://www.reddit.com",
        "wikipedia": "https://en.wikipedia.org", "amazon": "https://www.amazon.com", "netflix": "https://www.netflix.com",
        "twitter": "https://x.com", "x": "https://x.com", "facebook": "https://www.facebook.com",
        "instagram": "https://www.instagram.com", "linkedin": "https://www.linkedin.com", "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai", "hacker news": "https://news.ycombinator.com", "stack overflow": "https://stackoverflow.com",
        "twitch": "https://www.twitch.tv", "spotify": "https://open.spotify.com", "outlook": "https://outlook.office.com",
        "icloud": "https://www.icloud.com", "weather": "https://www.google.com/search?q=weather",
    ]

    /// Fixed phrasings and the key or action each means.
    static let phrases: [String: ControlAction] = {
        var p: [String: ControlAction] = [:]
        func add(_ names: [String], _ a: ControlAction) { for n in names { p[n] = a } }
        func k(_ key: String, cmd: Bool = true, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> ControlAction {
            .keys(KeyChord(key, command: cmd, shift: shift, option: opt, control: ctrl))
        }
        add(["new tab", "open a new tab", "open new tab", "open tab"], k("t"))
        add(["close tab", "close this tab", "close the tab", "close that tab"], k("w"))
        add(["close window", "close this window", "close the window"], k("w", shift: true))
        add(["new window", "open a new window", "open new window"], k("n"))
        add(["new private window", "new incognito window", "incognito", "private window"], k("n", shift: true))
        add(["reopen tab", "reopen closed tab", "reopen the tab", "reopen last tab", "undo close tab", "bring back that tab"],
            k("t", shift: true))
        add(["next tab"], k("tab", cmd: false, ctrl: true))
        add(["previous tab", "last tab", "prior tab"], k("tab", cmd: false, shift: true, ctrl: true))
        add(["go back", "back", "back page", "previous page"], k("["))
        add(["go forward", "forward", "next page"], k("]"))
        add(["reload", "refresh", "reload page", "refresh page", "reload the page", "refresh the page", "reload this page",
             "refresh this page"], k("r"))
        add(["copy", "copy that", "copy this", "copy it"], k("c"))
        add(["paste", "paste it", "paste that"], k("v"))
        add(["cut", "cut that", "cut this"], k("x"))
        add(["undo", "undo that"], k("z"))
        add(["redo", "redo that"], k("z", shift: true))
        add(["select all", "select everything", "highlight all", "highlight everything"], k("a"))
        add(["save", "save it", "save this", "save file", "save the file"], k("s"))
        add(["find", "find in page", "search this page", "search the page"], k("f"))
        add(["new document", "new file", "new note", "new message", "new email"], k("n"))
        add(["minimize", "minimize window", "minimize this", "minimize it", "minimize the window"], k("m"))
        add(["hide", "hide this", "hide it", "hide app", "hide this app"], k("h"))
        add(["full screen", "fullscreen", "go full screen", "enter full screen", "exit full screen", "toggle full screen"],
            k("f", ctrl: true))
        add(["zoom in", "bigger", "make it bigger"], k("="))
        add(["zoom out", "smaller", "make it smaller"], k("-"))
        add(["actual size", "reset zoom"], k("0"))
        add(["address bar", "focus address bar", "go to address bar", "url bar", "location bar"], k("l"))
        add(["spotlight", "open spotlight"], k("space"))
        add(["mission control", "show all windows"], k("up", cmd: false, ctrl: true))
        add(["lock screen", "lock the screen", "lock computer", "lock my computer", "lock the computer"], k("q", ctrl: true))
        add(["switch apps", "switch app", "previous app", "last app"], k("tab"))
        add(["go to top", "go to the top", "top", "top of page", "top of the page", "jump to top"], k("up"))
        add(["go to bottom", "go to the bottom", "bottom", "bottom of page", "bottom of the page", "jump to bottom"], k("down"))
        add(["page down"], k("pagedown", cmd: false))
        add(["page up"], k("pageup", cmd: false))
        add(["enter", "submit", "send it", "return"], k("return", cmd: false))
        add(["escape", "cancel that", "never mind", "nevermind"], k("escape", cmd: false))
        add(["quit", "quit this", "quit app", "quit this app", "quit it"], .quitApp(nil))
        add(["scroll down", "down", "scroll"], .scroll(.down))
        add(["scroll up", "up"], .scroll(.up))
        return p
    }()

    // MARK: Keys

    static let modifierWords: [String: WritableKeyPath<KeyChord, Bool>] = [
        "command": \.command, "cmd": \.command, "\u{2318}": \.command, "shift": \.shift, "option": \.option,
        "alt": \.option, "control": \.control, "ctrl": \.control,
    ]
    static let keyWords: [String: String] = [
        "enter": "return", "return": "return", "escape": "escape", "esc": "escape", "tab": "tab", "space": "space",
        "spacebar": "space", "space bar": "space", "delete": "delete", "backspace": "delete", "back space": "delete",
        "forward delete": "forwarddelete", "up": "up", "up arrow": "up", "arrow up": "up", "down": "down",
        "down arrow": "down", "arrow down": "down", "left": "left", "left arrow": "left", "arrow left": "left",
        "right": "right", "right arrow": "right", "arrow right": "right", "page up": "pageup", "page down": "pagedown",
        "home": "home", "end": "end", "comma": ",", "period": ".", "dot": ".", "slash": "/", "backslash": "\\",
        "equals": "=", "equal": "=", "plus": "=", "minus": "-", "dash": "-", "semicolon": ";", "quote": "'",
        "left bracket": "[", "right bracket": "]", "backtick": "`",
    ]

    /// "command shift t", "control tab", "enter" -> a chord; nil if the words are not keys.
    static func chord(_ words: [String]) -> KeyChord? {
        var c = KeyChord("")
        var rest = words.filter { $0 != "and" && $0 != "+" && $0 != "key" }
        while let f = rest.first, let kp = modifierWords[f] {
            c[keyPath: kp] = true
            rest.removeFirst()
            if rest.first == "plus" && rest.count > 1 { rest.removeFirst() }
        }
        let name = rest.joined(separator: " ")
        if let k = keyWords[name] {
            c.key = k
        } else if rest.count == 1, name.count == 1, let ch = name.first, ch.isLetter || ch.isNumber || "[]-=,./;'`".contains(ch) {
            c.key = name
        } else if rest.count == 1, name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) {
            c.key = name
        } else {
            return nil
        }
        return c
    }

    // MARK: Model output

    /// One action from a model's JSON ({"action": "open", "target": "spotify"}); nil for "none"
    /// or anything malformed. Model output only ever picks from the same closed set.
    public func action(fromModelJSON output: String) -> ControlAction? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (obj["action"] as? String)?.lowercased() else { return nil }
        let target = ((obj["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let site = (obj["site"] as? String).flatMap { SearchSite(rawValue: $0.lowercased()) } ?? .web
        switch kind {
        case "open":
            guard !target.isEmpty, case .action(let a, _) = open(Utterance(target).droppingArticles()) else { return nil }
            return a
        case "quit":
            if target.isEmpty { return .quitApp(nil) }
            return AppMatcher.match(target.lowercased(), among: apps).map { .quitApp($0.name) }
        case "url":
            return Self.url(from: Utterance(target).words).map { .openURL($0) }
        case "search":
            return target.isEmpty ? nil : .search(target, site: site)
        case "keys":
            return Self.chord(Utterance(target.replacingOccurrences(of: "+", with: " ")).words).map { .keys($0) }
        case "click":
            return target.isEmpty ? nil : .click(target)
        case "type":
            return target.isEmpty ? nil : .type(target)
        case "find":
            return target.isEmpty ? nil : .findInPage(target)
        case "scroll":
            return .scroll(ScrollDirection(rawValue: target.lowercased()) ?? .down)
        default:
            return nil
        }
    }
}

/// Picks the installed app a spoken name means.
public enum AppMatcher {
    public enum Strength: Int, Comparable, Sendable {
        case fuzzy = 1, prefix, exact
        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Match: Equatable, Sendable {
        public var name: String
        public var strength: Strength
    }

    /// Spoken names for apps whose display name differs; the first installed candidate wins.
    static let aliases: [String: [String]] = [
        "chrome": ["Google Chrome"], "google chrome": ["Google Chrome"], "vs code": ["Visual Studio Code"],
        "vscode": ["Visual Studio Code"], "code": ["Visual Studio Code"], "visual studio": ["Visual Studio Code"],
        "settings": ["System Settings", "System Preferences"], "system preferences": ["System Settings", "System Preferences"],
        "preferences": ["System Settings", "System Preferences"], "word": ["Microsoft Word"], "excel": ["Microsoft Excel"],
        "powerpoint": ["Microsoft PowerPoint"], "outlook": ["Microsoft Outlook"], "teams": ["Microsoft Teams"],
        "onenote": ["Microsoft OneNote"], "one note": ["Microsoft OneNote"], "imessage": ["Messages"], "texts": ["Messages"],
        "text messages": ["Messages"], "email": ["Mail"], "mail": ["Mail"], "apple music": ["Music"], "itunes": ["Music"],
        "zoom": ["zoom.us"], "iterm": ["iTerm"], "app store": ["App Store"], "the app store": ["App Store"],
        "calculator": ["Calculator"], "activity monitor": ["Activity Monitor"], "files": ["Finder"], "zen": ["Zen", "Zen Browser"],
        "arc": ["Arc"], "photos": ["Photos"], "maps": ["Maps"], "calendar": ["Calendar"], "notes": ["Notes"],
        "reminders": ["Reminders"], "terminal": ["Terminal"], "finder": ["Finder"], "safari": ["Safari"],
        "facetime": ["FaceTime"], "face time": ["FaceTime"], "preview": ["Preview"], "screenshot": ["Screenshot"],
        "chat gpt": ["ChatGPT"], "chatgpt": ["ChatGPT"], "claude": ["Claude"], "notion": ["Notion"],
    ]

    public static func match(_ spoken: String, among apps: [String]) -> Match? {
        let q = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = apps.map { ($0, $0.lowercased()) }
        if let hit = lower.first(where: { $0.1 == q }) { return Match(name: hit.0, strength: .exact) }
        if let names = aliases[q] {
            for n in names { if let hit = lower.first(where: { $0.1 == n.lowercased() }) { return Match(name: hit.0, strength: .exact) } }
        }
        // Spaces dropped or added by the recognizer: "power point", "facetime".
        let squashed = q.replacingOccurrences(of: " ", with: "")
        if let hit = lower.first(where: { $0.1.replacingOccurrences(of: " ", with: "") == squashed }) {
            return Match(name: hit.0, strength: .exact)
        }
        // Word prefix: "visual studio" -> "Visual Studio Code", "microsoft word" handled exactly.
        let qWords = q.split(separator: " ")
        let prefixHits = lower.filter { name in
            let words = name.1.split(separator: " ")
            return words.count >= qWords.count && Array(words[0..<qWords.count]) == qWords
        }
        if let hit = prefixHits.min(by: { $0.1.count < $1.1.count }) { return Match(name: hit.0, strength: .prefix) }
        // "word" -> "Microsoft Word": the spoken name is the app's last words.
        let suffixHits = lower.filter { name in
            let words = name.1.split(separator: " ")
            return words.count > qWords.count && Array(words.suffix(qWords.count)) == qWords
        }
        if suffixHits.count == 1, q.count >= 4 { return Match(name: suffixHits[0].0, strength: .prefix) }
        // A misheard name: small edit distance, scaled to length.
        guard q.count >= 4 else { return nil }
        let limit = q.count >= 8 ? 2 : 1
        let near = lower.map { ($0.0, editDistance(q, $0.1)) }.filter { $0.1 <= limit }.min { $0.1 < $1.1 }
        return near.map { Match(name: $0.0, strength: .fuzzy) }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// Apps in the usual folders, by display name ("Google Chrome" -> its bundle).
public enum InstalledApps {
    public static func scan() -> [String: URL] {
        var found: [String: URL] = [:]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home + "/Applications", "/System/Library/CoreServices/Applications"]
        func add(_ url: URL) {
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if found[name] == nil { found[name] = url }
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" { add(item); continue }
                // One level of folders: "/Applications/Microsoft Office/…".
                var dir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &dir), dir.boolValue,
                   let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    for i in inner where i.pathExtension == "app" { add(i) }
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return found
    }
}
