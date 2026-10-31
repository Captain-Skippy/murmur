import Foundation

/// How the cleanup should read in the focused app.
public enum AppStyle: String, Codable, Sendable, CaseIterable {
    case casual, formal, code, terminal, neutral

    /// Common apps. Overrides from settings take precedence (see `resolve`).
    public static let defaults: [String: AppStyle] = [
        // Chat
        "com.apple.MobileSMS": .casual, "com.tinyspeck.slackmacgap": .casual, "ru.keepcoder.Telegram": .casual,
        "io.element.elementx": .casual, "im.riot.app": .casual, "org.whispersystems.signal-desktop": .casual,
        "com.hnc.Discord": .casual, "net.whatsapp.WhatsApp": .casual,
        // Mail
        "com.apple.mail": .formal, "ch.protonmail.desktop": .formal, "com.microsoft.Outlook": .formal,
        // Code and agents
        "com.t3tools.t3code": .code, "dev.zed.Zed": .code, "dev.zed.Zed-Preview": .code, "com.apple.Terminal": .terminal,
        "com.mitchellh.ghostty": .terminal, "com.googlecode.iterm2": .terminal, "com.microsoft.VSCode": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor
        "com.openai.codex": .code, "com.anthropic.claudefordesktop": .neutral, "com.openai.chat": .neutral,
        "com.apple.dt.Xcode": .code,
    ]

    public static func resolve(bundleID: String?, url: String? = nil, overrides: [String: AppStyle] = [:]) -> AppStyle {
        guard let id = bundleID else { return .neutral }
        if let o = overrides[id] { return o }
        if let u = url?.lowercased() {
            if u.contains("mail.google.") || u.contains("mail.proton.") || u.contains("outlook.") { return .formal }
            if u.contains("github.com") { return .code }
            if u.contains("slack.com") || u.contains("discord.com") || u.contains("web.whatsapp") { return .casual }
        }
        return defaults[id] ?? .neutral
    }

    /// The per-style instruction block placed in the cleanup prompt.
    public var guidance: String {
        switch self {
        case .casual:
            return "Chat message. Keep it casual and short, as typed by the speaker. Sentence case; a single short sentence may drop its final period. No greeting or sign-off unless spoken."
        case .formal:
            return "Email or formal document. Complete sentences with full punctuation. Keep the speaker's greeting and sign-off if spoken, each on its own line; add none."
        case .code:
            return "Coding tool or agent chat that renders Markdown. Keep identifiers, file paths, CLI flags, commands, version numbers and casing exactly; wrap code identifiers, file names and commands in `backticks` when writing Markdown prose. Never translate technical terms. Plain, direct sentences."
        case .terminal:
            return "Terminal, usually talking to a coding agent. Keep identifiers, file paths, CLI flags, commands and casing exactly. Do not add backticks or quotes the speaker did not say; a shell may interpret them. Plain, direct sentences."
        case .neutral:
            return "General text. Clear sentences with standard punctuation."
        }
    }
}
