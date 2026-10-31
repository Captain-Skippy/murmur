import Foundation

/// How text reaches the focused app.
public enum InsertionMethod: String, Codable, Sendable {
    /// Save the pasteboard, write the text, Cmd+V, restore. One undo step in every app tried.
    case paste
    /// Set AXSelectedText on the focused element. Works without the pasteboard; undo varies by app.
    case accessibility
    /// Post the text as keyboard events. Slow for long text, but works where both others fail.
    case keystrokes
    /// Do not insert (secure field or nothing focused). Text stays in history.
    case none
}

/// What is known about the target when the text is ready.
public struct InsertionTarget: Sendable, Equatable {
    public var bundleID: String?
    /// AXSecureTextField, or secure event input is on (a password prompt anywhere).
    public var secure: Bool

    public init(bundleID: String?, secure: Bool = false) {
        self.bundleID = bundleID
        self.secure = secure
    }
}

public enum InsertionPlanner {
    /// Paste always, unless a per-app override from settings says otherwise; secure targets
    /// never receive text. A paste the target did not read is not remembered: one slow read
    /// must not move an app to a method it ignores while reporting success (AXSelectedText
    /// in some Electron apps does that).
    public static func choose(for t: InsertionTarget, overrides: [String: InsertionMethod] = [:]) -> InsertionMethod {
        if t.secure { return .none }
        if let id = t.bundleID, let o = overrides[id] { return o }
        return .paste
    }
}
