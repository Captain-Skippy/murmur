import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What is focused when dictation starts, read through Accessibility. Never screenshots.
struct FocusSnapshot: @unchecked Sendable {
    var bundleID: String?
    var appName: String?
    var pid: pid_t = 0
    var element: AXUIElement?
    var role: String?
    var secure = false
    var textBefore = ""
    var textAfter = ""
    var selectedText = ""
    var windowTitle: String?
    var url: String?
    /// Full value of the focused field (bounded), for correction learning.
    var value: String?

    /// Words from the surrounding text and window, for spelling names right.
    var contextTerms: [String] {
        let text = [windowTitle ?? "", textBefore.suffix(600).description, textAfter.prefix(200).description].joined(separator: " ")
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace || ",.;:!?()[]{}\"'".contains($0) }) {
            let w = String(raw)
            // Capitalized or mixed-case words and identifiers carry the spelling value.
            guard w.count > 2, w.first!.isUppercase || w.contains("_") || w.dropFirst().contains(where: \.isUppercase) else { continue }
            if seen.insert(w).inserted { out.append(w) }
        }
        return Array(out.suffix(40))
    }
}

enum Focus {
    private static var enabledManual = Set<pid_t>()

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// Secure input anywhere (a password prompt) or a secure field focused. Fast; runs before capture.
    static func isSecure(_ el: AXUIElement?) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let el else { return false }
        let role: String? = attr(el, kAXRoleAttribute)
        let sub: String? = attr(el, kAXSubroleAttribute)
        return role == "AXSecureTextField" || sub == "AXSecureTextField"
    }

    static func focusedElement() -> (AXUIElement?, NSRunningApplication?) {
        let app = NSWorkspace.shared.frontmostApplication
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var el: AXUIElement? = attr(sys, kAXFocusedUIElementAttribute)
        if el == nil, let pid = app?.processIdentifier {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            enableManualAccessibility(appEl, pid: pid)
            el = attr(appEl, kAXFocusedUIElementAttribute)
        }
        return (el, app)
    }

    /// Electron and Chromium apps build their accessibility tree only when asked.
    static func enableManualAccessibility(_ appEl: AXUIElement, pid: pid_t) {
        guard !enabledManual.contains(pid) else { return }
        enabledManual.insert(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func snapshot() -> FocusSnapshot {
        var s = FocusSnapshot()
        let (el, app) = focusedElement()
        s.bundleID = app?.bundleIdentifier
        s.appName = app?.localizedName
        s.pid = app?.processIdentifier ?? 0
        if let pid = app?.processIdentifier {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            enableManualAccessibility(appEl, pid: pid)
            if let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) {
                s.windowTitle = attr(win, kAXTitleAttribute)
            }
        }
        guard let el else { s.secure = IsSecureEventInputEnabled(); return s }
        AXUIElementSetMessagingTimeout(el, 0.15)
        s.element = el
        s.role = attr(el, kAXRoleAttribute)
        s.secure = isSecure(el)
        if s.secure { return s }
        s.selectedText = attr(el, kAXSelectedTextAttribute) ?? ""
        if let value: String = attr(el, kAXValueAttribute) {
            let ns = value as NSString
            s.value = ns.length > 20_000 ? nil : value
            var rangeRef: CFTypeRef?
            var range = CFRange(location: ns.length, length: 0)
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
                AXValueGetValue(rv as! AXValue, .cfRange, &range)
            }
            let loc = min(max(range.location, 0), ns.length)
            let end = min(loc + max(range.length, 0), ns.length)
            s.textBefore = ns.substring(to: loc)
            s.textAfter = ns.substring(from: end)
        }
        return s
    }
}
