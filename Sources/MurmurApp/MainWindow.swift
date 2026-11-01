import AVFoundation
import MurmurCore
import ServiceManagement
import SwiftUI

/// Murmur's one window: what the user touches and nothing else. Recent dictations, the
/// dictionary, a few settings. Problems appear as one banner; otherwise it stays quiet.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case home = "Home", dictionary = "Dictionary", settings = "Settings" }

    @Published var tab: Tab = .home
    @Published var recent: [HistoryEntry] = []
    @Published var proposals: [CorrectionDetector.Proposal] = []
    @Published var words: [DictionaryEntry] = []
    @Published var snippets: [Snippet] = []
    @Published var settings: MurmurSettings
    @Published var devices: [AudioCapture.InputDevice] = []
    @Published var problem: String?
    @Published var problemAction: (() -> Void)?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    let controller: DictationController
    var openRecorder: () -> Void = {}
    private var timer: Timer?
    private var historyChanges = -1

    init(controller: DictationController) {
        self.controller = controller
        settings = controller.settings
        reloadDictionary()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        // Every dictation still kept (historyDays), reread only after the store changed.
        if controller.history.changes != historyChanges || recent.isEmpty {
            historyChanges = controller.history.changes
            let r = controller.history.recent(limit: .max)
            if r != recent { recent = r }
        }
        if controller.proposals != proposals { proposals = controller.proposals }
        let d = AudioCapture.inputDevices()
        if d != devices { devices = d }
        // One problem at a time, in the order that matters.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            setProblem("Murmur needs the microphone to hear you.", "Allow") {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                else { Self.openPrivacy("Privacy_Microphone") }
            }
        } else if !AXIsProcessTrusted() {
            setProblem("Murmur needs Accessibility to type for you.", "Allow") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                Self.openPrivacy("Privacy_Accessibility")
            }
        } else if !controller.tap.installed {
            setProblem("Murmur can't see the fn key yet.", "Allow") {
                _ = CGRequestListenEventAccess()
                Self.openPrivacy("Privacy_ListenEvent")
            }
        } else if controller.status.hasPrefix("Model load failed") {
            setProblem("Murmur couldn't start its speech engine.", "Try again") { [weak self] in
                Task { await self?.controller.loadModels() }
            }
        } else if !controller.ready {
            setProblem("Getting ready…", nil, nil)
        } else if problem != nil {
            problem = nil
            problemAction = nil
        }
    }

    /// Previews hold their sample data still.
    func stopRefreshing() { timer?.invalidate() }

    private var problemButton: String?
    var problemButtonTitle: String? { problemButton }

    private func setProblem(_ text: String, _ button: String?, _ action: (() -> Void)?) {
        if problem != text { problem = text; problemButton = button; problemAction = action }
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: Dictionary

    func reloadDictionary() {
        let (d, s) = DictionaryFile.load()
        words = d.entries.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        snippets = s.sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
    }

    func saveWord(original: String?, term: String, sounds: [String]) {
        var (d, s) = DictionaryFile.load()
        if let o = original, PersonalDictionary.fold(o) != PersonalDictionary.fold(term) { d.remove(term: o) }
        d.replace(DictionaryEntry(term: term, sounds: sounds, source: .manual))
        commit(d, s)
    }

    func deleteWord(_ term: String) {
        var (d, s) = DictionaryFile.load()
        d.remove(term: term)
        commit(d, s)
    }

    func saveSnippet(original: String?, trigger: String, expansion: String) {
        var (d, s) = DictionaryFile.load()
        s.removeAll { $0.trigger.lowercased() == (original ?? trigger).lowercased() || $0.trigger.lowercased() == trigger.lowercased() }
        s.append(Snippet(trigger: trigger, expansion: expansion))
        commit(d, s)
    }

    func deleteSnippet(_ trigger: String) {
        var (d, s) = DictionaryFile.load()
        s.removeAll { $0.trigger == trigger }
        commit(d, s)
    }

    private func commit(_ d: PersonalDictionary, _ s: [Snippet]) {
        try? DictionaryFile.save(d, s)
        controller.reloadDictionary()
        reloadDictionary()
    }

    func accept(_ p: CorrectionDetector.Proposal) { controller.accept(p); reloadDictionary(); refresh() }
    func dismiss(_ p: CorrectionDetector.Proposal) { controller.dismiss(p); refresh() }

    // MARK: Settings

    func update(_ change: (inout MurmurSettings) -> Void) {
        change(&settings)
        try? settings.save()
        controller.update(settings)
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func appName(_ bundleID: String?) -> String? {
        guard let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Design system

/// One spacing scale, one set of radii, one accent: everything in the window and the HUD uses these.
enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
}

enum Radius {
    static let card: CGFloat = 12, control: CGFloat = 8, key: CGFloat = 4
}

enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// The teal of the app icon, darker in light mode so text and fills keep their contrast.
    static let accent = dynamic(light: 0x0B8790, dark: 0x22A99F)
    /// The icon's caret: the one warm color, used for Rewrite and learned words.
    static let warm = dynamic(light: 0xE07A1F, dark: 0xFFB04F)
    static let canvas = dynamic(light: 0xF2F3F5, dark: 0x1B1C1F)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x26282C)
    static let cardStroke = dynamic(light: 0x000000, dark: 0xFFFFFF, darkAlpha: 0.07, lightAlpha: 0.07)
    static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF, darkAlpha: 0.05, lightAlpha: 0.035)

    static let title = Font.system(size: 15, weight: .semibold)
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)

    /// The app icon: the bundle's AppIcon.icns; previews may set it from the repo.
    static var icon: NSImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = Space.l
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func card(padding: CGFloat = Space.l) -> some View { modifier(CardBackground(padding: padding)) }
}

/// A heading over a group of cards, with an optional note on the right.
struct SectionHeader: View {
    let title: String
    var note: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.section)
            Spacer()
            if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, Space.xs)
    }
}

/// A key drawn as a key, for the hints in the header.
struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: Radius.key, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.key, style: .continuous).strokeBorder(Theme.cardStroke))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
    }
}

// MARK: - Window

extension HotkeyChoice {
    /// The dictation key as it is printed on the keyboard.
    var keycap: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right \u{2325}"
        case .rightCommand: "right \u{2318}"
        case .rightControl: "right \u{2303}"
        case .rightShift: "right \u{21E7}"
        }
    }
}

struct MainView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $m.tab) {
                ForEach(AppModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.bottom, Space.l)
            Group {
                switch m.tab {
                case .home: HomeView(m: m)
                case .dictionary: DictionaryView(m: m)
                case .settings: SettingsPane(m: m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 480, height: 600)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    var header: some View {
        HStack(spacing: Space.m) {
            Image(nsImage: Theme.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .padding(-4) // the icon's own transparent margin
            VStack(alignment: .leading, spacing: 6) {
                Text("Murmur").font(Theme.title)
                HStack(spacing: Space.m) {
                    hint([m.settings.dictationKey.keycap], "Hold to dictate")
                    hint([m.settings.dictationKey.keycap, "space"], "Hands-free")
                    hint(["esc"], "Cancel")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, 32) // clears the traffic lights
        .padding(.bottom, Space.l)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: Space.xs) {
            HStack(spacing: 2) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
            Text(text).font(Theme.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

struct Banner: View {
    @ObservedObject var m: AppModel
    var body: some View {
        if let p = m.problem {
            let waiting = m.problemAction == nil
            HStack(spacing: Space.m) {
                ZStack {
                    Circle().fill(waiting ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.16))
                    if waiting { ProgressView().controlSize(.small) } else {
                        Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                    }
                }
                .frame(width: 28, height: 28)
                Text(p).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s)
                if let a = m.problemAction, let t = m.problemButtonTitle {
                    Button(t, action: a).buttonStyle(.borderedProminent).tint(.orange).buttonBorderShape(.capsule)
                }
            }
            .padding(Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(waiting ? AnyShapeStyle(Theme.card) : AnyShapeStyle(Color.orange.opacity(0.10))))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(waiting ? AnyShapeStyle(Theme.cardStroke) : AnyShapeStyle(Color.orange.opacity(0.35))))
        }
    }
}

// MARK: Home

struct HomeView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Banner(m: m)
                if !m.proposals.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        SectionHeader(title: "Learned from your edits")
                        VStack(spacing: 0) {
                            ForEach(Array(m.proposals.enumerated()), id: \.element) { i, p in
                                if i > 0 { Divider().padding(.horizontal, Space.l) }
                                ProposalRow(p: p, add: { m.accept(p) }, dismiss: { m.dismiss(p) })
                            }
                        }
                        .card(padding: 0)
                    }
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    SectionHeader(title: "Recent")
                        .padding(.bottom, -Space.xs) // cards below are 12 apart; the header stays 8 above the first
                    if m.recent.isEmpty {
                        EmptyRecent(key: m.settings.dictationKey.keycap, days: m.settings.historyDays)
                    }
                    LazyVStack(alignment: .leading, spacing: Space.m) {
                        ForEach(RecentDay.group(m.recent)) { day in
                            Text(day.title).font(Theme.caption).foregroundStyle(.secondary)
                                .padding(.top, day.isFirst ? 0 : Space.s).padding(.leading, Space.xs)
                            ForEach(day.entries) { e in
                                RecentCard(e: e, copy: { m.controller.copy(e) }, insert: { NSApp.hide(nil); m.controller.reinsert(e) })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xl)
        }
        .scrollIndicators(.never)
    }
}

struct ProposalRow: View {
    let p: CorrectionDetector.Proposal
    let add: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text(p.heard).strikethrough(color: .secondary).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text(p.corrected).fontWeight(.semibold)
            }
            .font(Theme.body)
            .lineLimit(1)
            Spacer(minLength: Space.s)
            Button("Add to dictionary", action: add)
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }
}

struct RecentCard: View {
    let e: HistoryEntry
    let copy: () -> Void
    let insert: () -> Void
    @State private var copied = false
    private static let rel: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()

    private var appIcon: NSImage? {
        guard let id = e.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(e.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.body).lineSpacing(2).lineLimit(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.s) {
                if let icon = appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(AppModel.appName(e.app) ?? "Unknown app").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(Self.rel.localizedString(for: e.at, relativeTo: Date())).font(Theme.caption).foregroundStyle(.tertiary)
                Spacer(minLength: Space.s)
                Button {
                    copy()
                    withAnimation(.snappy) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy) { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button(action: insert) { Label("Insert", systemImage: "text.insert") }
                    .help("Type it again into the app you were in")
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).labelStyle(.titleAndIcon)
        }
        .card()
    }
}

/// Recent dictations by local calendar day, newest first: "Today", "Yesterday", then dates.
struct RecentDay: Identifiable {
    let id: Date
    let title: String
    let entries: [HistoryEntry]
    let isFirst: Bool

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMMd")
        return f
    }()

    static func group(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [RecentDay] {
        var days: [(Date, [HistoryEntry])] = []
        for e in entries {
            let d = calendar.startOfDay(for: e.at)
            if days.last?.0 == d { days[days.count - 1].1.append(e) } else { days.append((d, [e])) }
        }
        return days.enumerated().map { i, day in
            let title = calendar.isDateInToday(day.0) ? "Today"
                : calendar.isDateInYesterday(day.0) ? "Yesterday" : dateFormat.string(from: day.0)
            return RecentDay(id: day.0, title: title, entries: day.1, isFirst: i == 0)
        }
    }
}

struct EmptyRecent: View {
    let key: String
    let days: Int
    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            Text("Nothing dictated yet").font(.system(size: 13, weight: .medium))
            Text("Hold \(key) in any app and speak. Your dictations from the last \(days) days appear here.")
                .font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .card()
    }
}

// MARK: Dictionary

struct DictionaryView: View {
    @ObservedObject var m: AppModel
    enum Kind: String, CaseIterable { case words = "Words", snippets = "Snippets" }
    @State private var kind: Kind = .words
    @State private var search = ""
    @State private var editingWord: DictionaryEntry?
    @State private var editingSnippet: Snippet?
    @State private var addingWord = false
    @State private var addingSnippet = false

    private var words: [DictionaryEntry] { m.words.filter { search.isEmpty || $0.term.localizedCaseInsensitiveContains(search) } }
    private var snippets: [Snippet] {
        m.snippets.filter { search.isEmpty || $0.trigger.localizedCaseInsensitiveContains(search) || $0.expansion.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Picker("", selection: $kind) {
                    Text("Words \(m.words.count)").tag(Kind.words)
                    Text("Snippets \(m.snippets.count)").tag(Kind.snippets)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                SearchField(text: $search)
                Button { if kind == .words { addingWord = true } else { addingSnippet = true } } label: {
                    Label(kind == .words ? "Add word" : "Add snippet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
            Text(kind == .words ? "Names and terms Murmur should always spell your way."
                                : "Say the phrase on its own and Murmur types the text instead.")
                .font(Theme.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Space.xs)
            list
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.xl)
        .sheet(isPresented: $addingWord) { WordEditor(m: m, original: nil) }
        .sheet(item: $editingWord) { w in WordEditor(m: m, original: w) }
        .sheet(isPresented: $addingSnippet) { SnippetEditor(m: m, original: nil) }
        .sheet(item: $editingSnippet) { s in SnippetEditor(m: m, original: s) }
    }

    @ViewBuilder private var list: some View {
        let empty = kind == .words ? words.isEmpty : snippets.isEmpty
        if empty {
            VStack(spacing: Space.xs) {
                Text(!search.isEmpty ? "No matches for \u{201C}\(search)\u{201D}" : kind == .words ? "No words yet" : "No snippets yet")
                    .font(.system(size: 13, weight: .medium))
                if search.isEmpty {
                    Text(kind == .words ? "Add a name Murmur gets wrong, with the ways it mishears it."
                                        : "Add a phrase like \u{201C}my email\u{201D} and the text it stands for.")
                        .font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if kind == .words {
                        ForEach(Array(words.enumerated()), id: \.element.term) { i, w in
                            Row(title: w.term, subtitle: w.sounds.isEmpty ? nil : "Heard as " + w.sounds.joined(separator: ", "),
                                divider: i > 0, edit: { editingWord = w }, delete: { m.deleteWord(w.term) })
                        }
                    } else {
                        ForEach(Array(snippets.enumerated()), id: \.element.trigger) { i, s in
                            Row(title: "\u{201C}\(s.trigger)\u{201D}", subtitle: s.expansion.replacingOccurrences(of: "\n", with: " "),
                                divider: i > 0, edit: { editingSnippet = s }, delete: { m.deleteSnippet(s.trigger) })
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            .card(padding: 0)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    struct Row: View {
        let title: String
        let subtitle: String?
        let divider: Bool
        let edit: () -> Void
        let delete: () -> Void
        @State private var hover = false
        var body: some View {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let s = subtitle { Text(s).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: Space.s)
                HStack(spacing: Space.xs) {
                    IconButton(symbol: "pencil", help: "Edit", action: edit)
                    IconButton(symbol: "trash", help: "Delete", action: delete)
                }
                .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(hover ? Theme.hover : .clear))
            .overlay(alignment: .top) { if divider && !hover { Divider().padding(.horizontal, Space.m).offset(y: -0.5) } }
            .padding(.horizontal, Space.xs)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2, perform: edit)
            .contextMenu { Button("Edit", action: edit); Button("Delete", role: .destructive, action: delete) }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain).font(Theme.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.s)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension DictionaryEntry: Identifiable { public var id: String { term } }
extension Snippet: Identifiable { public var id: String { trigger } }

/// The shared frame of the word and snippet sheets.
struct EditorSheet<Fields: View>: View {
    let title: String
    let canSave: Bool
    let save: () -> Void
    @ViewBuilder let fields: Fields
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(title).font(Theme.title)
            fields
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).tint(.primary)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!canSave)
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .frame(width: 380)
    }
}

struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content
        }
    }
}

struct WordEditor: View {
    @ObservedObject var m: AppModel
    let original: DictionaryEntry?
    @State private var term = ""
    @State private var sounds = ""

    var body: some View {
        EditorSheet(title: original == nil ? "Add a word" : "Edit word",
                    canSave: !term.trimmingCharacters(in: .whitespaces).isEmpty,
                    save: {
                        m.saveWord(original: original?.term, term: term.trimmingCharacters(in: .whitespaces),
                                   sounds: sounds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    }) {
            Field(label: "Spelling") { TextField("Kai Merrow", text: $term).textFieldStyle(.roundedBorder) }
            Field(label: "Sometimes heard as (optional, comma separated)") {
                TextField("kai marrow, kai mero", text: $sounds).textFieldStyle(.roundedBorder)
            }
        }
        .onAppear { term = original?.term ?? ""; sounds = original?.sounds.joined(separator: ", ") ?? "" }
    }
}

struct SnippetEditor: View {
    @ObservedObject var m: AppModel
    let original: Snippet?
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        EditorSheet(title: original == nil ? "Add a snippet" : "Edit snippet",
                    canSave: !trigger.trimmingCharacters(in: .whitespaces).isEmpty && !expansion.isEmpty,
                    save: { m.saveSnippet(original: original?.trigger, trigger: trigger.trimmingCharacters(in: .whitespaces), expansion: expansion) }) {
            Field(label: "When I say") { TextField("my email", text: $trigger).textFieldStyle(.roundedBorder) }
            Field(label: "Type this") {
                TextEditor(text: $expansion).font(Theme.body).scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous).strokeBorder(Theme.cardStroke))
            }
        }
        .onAppear { trigger = original?.trigger ?? ""; expansion = original?.expansion ?? "" }
    }
}

// MARK: Settings

struct SettingsPane: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        SectionHeader(title: "Microphone")
                        VStack(alignment: .leading, spacing: 0) {
                            SettingRow(title: "Input",
                                       detail: "Automatic uses the Mac's built-in microphone, so AirPods stay in music mode; a headset or external mic only when the Mac has none. Choosing AirPods puts them in call mode, where music drops out briefly whenever a sound starts or stops.") {
                                Picker("Microphone", selection: Binding(get: { m.settings.microphone }, set: { v in m.update { $0.microphone = v } })) {
                                    Text("Automatic").tag("automatic")
                                    Text("Built-in microphone").tag("builtin")
                                    let others = m.devices.filter { !$0.builtIn }
                                    if !others.isEmpty { Divider() }
                                    ForEach(others) { d in Text(d.name).tag(d.uid) }
                                }
                                .labelsHidden().frame(maxWidth: 180)
                            }
                            Divider().padding(.horizontal, Space.l)
                            SettingRow(title: "Keep the microphone warm",
                                       detail: "Stays on for 10 minutes after dictating, so the next dictation starts instantly and catches words said as you press the key. The orange mic dot shows while it is on.") {
                                Switch(isOn: Binding(get: { m.settings.warmMicMinutes > 0 }, set: { v in m.update { $0.warmMicMinutes = v ? 10 : 0 } }))
                            }
                        }
                        .card(padding: 0)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        SectionHeader(title: "General")
                        VStack(alignment: .leading, spacing: 0) {
                            SettingRow(title: "Play sounds in headphones when recording starts and stops") {
                                Switch(isOn: Binding(get: { m.settings.sounds }, set: { v in m.update { $0.sounds = v } }))
                            }
                            Divider().padding(.horizontal, Space.l)
                            SettingRow(title: "Open Murmur at login") {
                                Switch(isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                            }
                        }
                        .card(padding: 0)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.never)
            HStack {
                Text("Murmur \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(Theme.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Murmur") { NSApp.terminate(nil) }.buttonBorderShape(.capsule).tint(.primary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.l)
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.l) {
                Text(title).font(Theme.body)
                Spacer(minLength: 0)
                control
            }
            if let detail {
                Text(detail).font(Theme.caption).foregroundStyle(.secondary).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, Space.xl)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: 44)
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

// MARK: - Design previews

/// `Murmur --snapshot DIR`: render each tab of the window in light and dark, and each HUD
/// phase, to PNG and exit (for design review). Run from the repo so it finds the icon.
@MainActor func snapshot(to dir: String) {
    if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { Theme.icon = icon }
    let model = AppModel(controller: DictationController())
    model.stopRefreshing()
    func sample(_ problem: Bool) {
        model.recent = [HistoryEntry(at: Date().addingTimeInterval(-90), app: "com.apple.Terminal", raw: "",
                                     text: "Can you check the README and make sure the install steps still work?", inserted: true),
                        HistoryEntry(at: Date().addingTimeInterval(-600), app: "com.apple.MobileSMS", raw: "",
                                     text: "Running 10 min late, save me a seat", inserted: true),
                        HistoryEntry(at: Date().addingTimeInterval(-86_400 - 3600), app: "com.apple.mail", raw: "",
                                     text: "Thanks, I'll send the draft over tonight.", inserted: true)]
        model.proposals = [CorrectionDetector.Proposal(heard: "Sara", corrected: "Sarah"),
                           CorrectionDetector.Proposal(heard: "kai marrow", corrected: "Kai Merrow")]
        model.words = [DictionaryEntry(term: "Kai Merrow", sounds: ["kai marrow", "kai mero"], source: .manual),
                       DictionaryEntry(term: "Murmur", sounds: [], source: .manual),
                       DictionaryEntry(term: "Tailscale", sounds: ["tail scale"], source: .manual),
                       DictionaryEntry(term: "Qwen", sounds: ["quen", "gwen"], source: .manual)]
        model.snippets = [Snippet(trigger: "my email", expansion: "sam@example.com"),
                          Snippet(trigger: "sign off", expansion: "Thanks,\nSam")]
        if problem { model.problem = "Murmur needs Accessibility to type for you."; model.problemAction = {} } else { model.problem = nil; model.problemAction = nil }
    }
    func render(_ view: NSView, _ size: NSSize, _ dark: Bool, _ name: String, chrome: Bool = true) {
        view.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: view.frame, styleMask: chrome ? [.titled, .closable, .miniaturizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let frame = chrome ? view.superview ?? view : view // the window frame, with its traffic lights
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    for dark in [false, true] {
        for tab in AppModel.Tab.allCases {
            sample(tab == .home && dark)
            model.tab = tab
            render(NSHostingView(rootView: MainView(m: model).environment(\.controlActiveState, .key)), NSSize(width: 480, height: 600), dark, "\(tab.rawValue)-\(dark ? "dark" : "light")")
        }
        sample(false)
        model.recent = []; model.proposals = []
        model.tab = .home
        render(NSHostingView(rootView: MainView(m: model)), NSSize(width: 480, height: 600), dark, "Home-empty-\(dark ? "dark" : "light")")
        sample(false)
        let word = NSHostingView(rootView: WordEditor(m: model, original: model.words[0]).environment(\.controlActiveState, .key).background(.windowBackground))
        render(word, word.fittingSize, dark, "WordEditor-\(dark ? "dark" : "light")", chrome: false)
        let snip = NSHostingView(rootView: SnippetEditor(m: model, original: model.snippets[1]).environment(\.controlActiveState, .key).background(.windowBackground))
        render(snip, snip.fittingSize, dark, "SnippetEditor-\(dark ? "dark" : "light")", chrome: false)
    }
    let phases: [(String, HUDModel.Phase)] = [("recording", .recording(handsFree: false, command: false)),
                                               ("handsfree", .recording(handsFree: true, command: false)),
                                               ("rewrite", .recording(handsFree: false, command: true)),
                                               ("rewrite-handsfree", .recording(handsFree: true, command: true)),
                                               ("control", .recording(handsFree: false, command: false, control: true)),
                                               ("control-handsfree", .recording(handsFree: true, command: false, control: true)),
                                               ("processing", .processing),
                                               ("message", .message("Learned \u{201C}Sarah\u{201D}. Open Murmur to add it.")),
                                               ("message-long", .message(String(repeating: "A very long message that keeps going ", count: 4)))]
    for (name, phase) in phases {
        let hud = HUDModel()
        hud.phase = phase
        for (i, v) in [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 1.0, 0.5, 0.3, 0.6, 0.45, 0.25, 0.1].enumerated() { hud.levels[i] = v }
        for dark in [false, true] {
            let backdrop = ZStack {
                LinearGradient(colors: dark ? [Color(white: 0.12), Color(white: 0.2)] : [Color(white: 0.97), Color(red: 0.85, green: 0.9, blue: 0.95)],
                               startPoint: .top, endPoint: .bottom)
                HUDView(model: hud)
            }
            render(NSHostingView(rootView: backdrop), HUDController.size, dark, "HUD-\(name)-\(dark ? "dark" : "light")", chrome: false)
        }
    }
}
