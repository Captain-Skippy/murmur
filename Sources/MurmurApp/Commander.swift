import AppKit
import ApplicationServices
import MurmurCore

/// Carries out voice-control actions with the Mac's own interfaces: Launch Services for apps,
/// URLs and folders, keyboard and scroll events, and Accessibility to press a control by name.
/// Never screenshots, never scripts.
@MainActor
final class Commander {
    /// Display name -> app bundle, from the usual app folders and whatever is running.
    private(set) var apps: [String: URL] = [:]
    private var indexedAt = Date.distantPast
    private var browsers: Set<URL> = []
    private let inserter: Inserter
    private let insertionOverrides: () -> [String: InsertionMethod]

    init(inserter: Inserter, insertionOverrides: @escaping () -> [String: InsertionMethod]) {
        self.inserter = inserter
        self.insertionOverrides = insertionOverrides
    }

    var parser: ControlParser {
        refreshIfStale()
        return ControlParser(apps: Array(apps.keys))
    }

    // MARK: App index

    /// Rescans at most once a minute: a few hundred directory entries, a few milliseconds.
    func refreshIfStale() {
        guard Date().timeIntervalSince(indexedAt) > 60 else { return }
        indexedAt = Date()
        var found = InstalledApps.scan()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let n = app.localizedName, let u = app.bundleURL, found[n] == nil { found[n] = u }
        }
        apps = found
        if let probe = URL(string: "https://example.com") {
            browsers = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).map(\.standardizedFileURL))
        }
    }

    // MARK: Actions

    /// Performs one action; false (with a reason) when it could not.
    func perform(_ action: ControlAction) async -> (ok: Bool, why: String?) {
        switch action {
        case .openApp(let name):
            guard let url = apps[name] else { return (false, "No app named \(name)") }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) } catch {
                return (false, "Could not open \(name)")
            }
            await waitForFront(url)
            return (true, nil)
        case .quitApp(let name):
            let target: NSRunningApplication?
            if let name {
                target = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName == name || ($0.bundleURL != nil && $0.bundleURL?.standardizedFileURL == apps[name]?.standardizedFileURL)
                }
            } else {
                target = NSWorkspace.shared.frontmostApplication
            }
            guard let app = target else { return (false, "\(name ?? "That app") is not running") }
            guard app.bundleIdentifier != "com.apple.finder", app.processIdentifier != getpid() else { return (false, "Not quitting that") }
            return (app.terminate(), nil)
        case .openURL(let s):
            guard let url = URL(string: s) else { return (false, "Bad address") }
            return await open(url)
        case .search(let q, let site):
            guard let url = URL(string: site.url(q)) else { return (false, "Bad search") }
            return await open(url)
        case .openFolder(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return (NSWorkspace.shared.open(URL(fileURLWithPath: expanded)), nil)
        case .keys(let chord):
            guard Self.post(chord) else { return (false, "Unknown key \(chord.key)") }
            return (true, nil)
        case .click(let name):
            return await click(name)
        case .type(let text):
            let outcome = await inserter.insert(text, into: Focus.snapshot(), overrides: insertionOverrides())
            return (outcome.ok, outcome.ok ? nil : "Could not type here")
        case .findInPage(let text):
            _ = Self.post(KeyChord("f", command: true))
            try? await Task.sleep(for: .milliseconds(180))
            let outcome = await inserter.insert(text, into: Focus.snapshot(), overrides: insertionOverrides())
            return (outcome.ok, nil)
        case .scroll(let d):
            Self.scroll(d)
            return (true, nil)
        case .media(let m):
            Self.postMedia(m)
            return (true, nil)
        }
    }

    /// Web pages open in the frontmost browser when one is in front, else the default browser.
    private func open(_ url: URL) async -> (ok: Bool, why: String?) {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, browsers.contains(front) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: front, configuration: config)
                return (true, nil)
            } catch {}
        }
        return (NSWorkspace.shared.open(url), nil)
    }

    /// Keys sent right after opening an app must reach it: wait until it is in front (≤ 1.5 s).
    private func waitForFront(_ url: URL) async {
        let want = url.standardizedFileURL
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == want { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A window still drawing ignores the first keys.
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: Keys and scrolling

    /// Marks events Murmur posts, so its own key tap lets them pass (an Escape it sends must not
    /// cancel the recording that asked for it).
    nonisolated static let syntheticMark: Int64 = 0x4D55524D  // "MURM"

    static let namedCodes: [String: CGKeyCode] = [
        "return": 36, "escape": 53, "tab": 48, "space": 49, "delete": 51, "forwarddelete": 117, "up": 126, "down": 125,
        "left": 123, "right": 124, "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]
    /// US positions, when the current layout cannot type the character.
    static let ansiCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    @discardableResult
    static func post(_ chord: KeyChord) -> Bool {
        let code: CGKeyCode
        if let c = namedCodes[chord.key] {
            code = c
        } else if chord.key.count == 1, let ch = chord.key.first {
            guard let c = Inserter.keyCode(for: ch) ?? ansiCodes[ch] else { return false }
            code = c
        } else {
            return false
        }
        var flags: CGEventFlags = []
        if chord.command { flags.insert(.maskCommand) }
        if chord.shift { flags.insert(.maskShift) }
        if chord.option { flags.insert(.maskAlternate) }
        if chord.control { flags.insert(.maskControl) }
        if chord.fn { flags.insert(.maskSecondaryFn) }
        if ["up", "down", "left", "right", "pageup", "pagedown", "home", "end", "forwarddelete"].contains(chord.key)
            || chord.key.hasPrefix("f") && chord.key.count > 1 {
            flags.insert(.maskSecondaryFn)
            if ["up", "down", "left", "right"].contains(chord.key) { flags.insert(.maskNumericPad) }
        }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return false }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMark)
            e.post(tap: .cghidEventTap)
        }
        return true
    }

    /// A media key, as the keyboard sends it (NX_KEYTYPE_* in a system-defined event).
    static func postMedia(_ key: MediaKey) {
        let code: Int = switch key {
        case .volumeUp: 0
        case .volumeDown: 1
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (code << 16) | (state << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Scroll the frontmost window (aimed at its middle, the pointer stays put).
    static func scroll(_ d: ScrollDirection) {
        let lines: Int32 = 8
        let (dy, dx): (Int32, Int32) = switch d {
        case .down: (-lines, 0)
        case .up: (lines, 0)
        case .left: (0, lines)
        case .right: (0, -lines)
        }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        if let center = frontWindowCenter() { e.location = center }
        e.setIntegerValueField(.eventSourceUserData, value: syntheticMark)
        e.post(tap: .cghidEventTap)
    }

    static func frontWindowCenter() -> CGPoint? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let win: AXUIElement = Focus.attr(app, kAXFocusedWindowAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv: AXValue = axValue(win, kAXPositionAttribute), let sv: AXValue = axValue(win, kAXSizeAttribute),
              AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    private static func axValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    // MARK: Clicking by name

    /// Find a control in the frontmost window (then its menu bar) whose label matches, and press it.
    private func click(_ name: String) async -> (ok: Bool, why: String?) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return (false, "No app in front") }
        let found = await Task.detached { ControlFinder.find(name, pid: pid) }.value
        guard let el = found else { return (false, "No \u{201C}\(name)\u{201D} on screen") }
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return (true, nil) }
        // Web content often has no press action: click its middle.
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = Self.axValue(el, kAXPositionAttribute), let sv = Self.axValue(el, kAXSizeAttribute),
              AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return (false, "Could not press it") }
        let at = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        let back = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
            e?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMark)
            e?.post(tap: .cghidEventTap)
        }
        if let back { CGWarpMouseCursorPosition(back) }
        return (true, nil)
    }
}

/// A bounded breadth-first walk of an app's accessibility tree for a control by its label.
enum ControlFinder {
    static let pressable: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
                                         "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow",
                                         "AXStaticText", "AXImage", "AXTextField", "AXComboBox"]

    static func find(_ name: String, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        Focus.enableManualAccessibility(app, pid: pid)
        let want = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var roots: [AXUIElement] = []
        if let w: AXUIElement = Focus.attr(app, kAXFocusedWindowAttribute) { roots.append(w) }
        if let m: AXUIElement = Focus.attr(app, kAXMenuBarAttribute) { roots.append(m) }
        let deadline = Date().addingTimeInterval(1.5)
        var partial: (AXUIElement, Int)?
        for root in roots {
            var queue: [AXUIElement] = [root]
            var seen = 0
            while !queue.isEmpty, seen < 8000, Date() < deadline {
                let el = queue.removeFirst()
                seen += 1
                AXUIElementSetMessagingTimeout(el, 0.1)
                let role: String = Focus.attr(el, kAXRoleAttribute) ?? ""
                if pressable.contains(role) {
                    // Static text and images only count when nothing better (a button) has the name.
                    let weak = ["AXStaticText", "AXImage", "AXCell", "AXRow", "AXTextField", "AXComboBox"].contains(role)
                    for label in labels(el) {
                        let l = label.lowercased()
                        if l == want, !weak { return el }
                        if l == want, partial == nil || partial!.1 > 0 { partial = (el, 0) }
                        else if l.contains(want), want.count >= 3, partial == nil { partial = (el, 1) }
                    }
                }
                // Menus stay closed: their items are listed but walking them is slow and noisy.
                if role == "AXMenu" { continue }
                if let kids: [AXUIElement] = Focus.attr(el, kAXChildrenAttribute) { queue.append(contentsOf: kids) }
            }
        }
        return partial?.0
    }

    static func labels(_ el: AXUIElement) -> [String] {
        var out: [String] = []
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute] {
            if let s: String = Focus.attr(el, a), !s.isEmpty, s.count < 120 { out.append(s) }
        }
        if let t: AXUIElement = Focus.attr(el, kAXTitleUIElementAttribute), let s: String = Focus.attr(t, kAXValueAttribute) { out.append(s) }
        return out
    }
}
