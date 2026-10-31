import AppKit
import AVFoundation
import MurmurCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = DictationController()
    private var item: NSStatusItem?
    private var tapRetry: Timer?
    private var recorderWindow: NSWindow?
    private var recorder: EvalRecorder?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        if controller.settings.menuBarIcon { showMenuBarIcon() }
        controller.onStatusChange = { [weak self] in self?.updateIcon() }

        requestPermissions()
        // A dictation app starts with the Mac: register once; it can be turned off in Settings.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }
        if permissionState().contains(where: { !$0.1 }) { openSettings() }
        Task { await controller.loadModels() }
        installTapWhenAllowed()
    }

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }

    /// The key tap needs Accessibility and Input Monitoring; retry until they are granted.
    private func installTapWhenAllowed() {
        if controller.installTap() { updateIcon(); return }
        controller.setStatus("Waiting for Accessibility and Input Monitoring")
        tapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.writeStatus()
                if self.controller.installTap() {
                    t.invalidate()
                    self.controller.setStatus(self.controller.ready ? "Ready" : self.controller.status)
                }
            }
        }
    }

    func showMenuBarIcon() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        let menu = NSMenu()
        menu.delegate = self
        it.menu = menu
        item = it
    }

    /// Without a menu bar icon, opening Murmur again shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func updateIcon() {
        writeStatus()
        let ok = controller.ready && controller.tap.installed
        item?.button?.image = NSImage(systemSymbolName: ok ? "waveform" : "waveform.slash", accessibilityDescription: "Murmur")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = controller.settings
        menu.addItem(withTitle: controller.status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Hold \(s.dictationKey.label) to dictate; double-tap for hands-free", action: nil, keyEquivalent: "").isEnabled = false
        if let k = s.rewriteKey {
            menu.addItem(withTitle: "Hold \(k.label) with text selected to rewrite it", action: nil, keyEquivalent: "").isEnabled = false
        }
        for (name, granted) in permissionState() where !granted {
            menu.addItem(withTitle: "Missing permission: \(name)", action: #selector(openPrivacy), keyEquivalent: "").target = self
        }
        if !controller.proposals.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Dictionary suggestions", action: nil, keyEquivalent: "").isEnabled = false
            for (i, p) in controller.proposals.enumerated() {
                let mi = NSMenuItem(title: "\(p.heard) -> \(p.corrected)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let a = sub.addItem(withTitle: "Add \"\(p.corrected)\"", action: #selector(acceptProposal(_:)), keyEquivalent: "")
                a.target = self; a.tag = i
                let d = sub.addItem(withTitle: "Dismiss", action: #selector(dismissProposal(_:)), keyEquivalent: "")
                d.target = self; d.tag = i
                mi.submenu = sub
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let recent = controller.history.recent(limit: 10)
        let head = menu.addItem(withTitle: recent.isEmpty ? "No recent dictations" : "Recent", action: nil, keyEquivalent: "")
        head.isEnabled = false
        for e in recent {
            let title = e.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let mi = NSMenuItem(title: title.count > 60 ? String(title.prefix(57)) + "..." : title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let c = sub.addItem(withTitle: "Copy", action: #selector(copyEntry(_:)), keyEquivalent: "")
            c.target = self; c.representedObject = e.id
            let r = sub.addItem(withTitle: "Insert again", action: #selector(reinsertEntry(_:)), keyEquivalent: "")
            r.target = self; r.representedObject = e.id
            mi.submenu = sub
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Record eval set...", action: #selector(openRecorder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func writeStatus() {
        let p = Dictionary(uniqueKeysWithValues: permissionState())
        AppStatus(pid: ProcessInfo.processInfo.processIdentifier,
                  version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                  status: controller.status, ready: controller.ready, recognizer: controller.settings.recognizer,
                  cleaner: controller.settings.cleaner, microphone: p["Microphone"] ?? false,
                  accessibility: p["Accessibility"] ?? false, inputMonitoring: p["Input Monitoring"] ?? false,
                  tapInstalled: controller.tap.installed, micOpenUntil: controller.micOpenUntil).write()
    }

    func permissionState() -> [(String, Bool)] {
        [("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
         ("Accessibility", AXIsProcessTrusted()),
         ("Input Monitoring", CGPreflightListenEventAccess())]
    }

    private func entry(_ sender: NSMenuItem) -> HistoryEntry? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return controller.history.recent(limit: 10).first { $0.id == id }
    }

    @objc func acceptProposal(_ sender: NSMenuItem) {
        guard controller.proposals.indices.contains(sender.tag) else { return }
        controller.accept(controller.proposals[sender.tag])
    }

    @objc func dismissProposal(_ sender: NSMenuItem) {
        guard controller.proposals.indices.contains(sender.tag) else { return }
        controller.dismiss(controller.proposals[sender.tag])
    }

    @objc func copyEntry(_ sender: NSMenuItem) { if let e = entry(sender) { controller.copy(e) } }
    @objc func reinsertEntry(_ sender: NSMenuItem) { if let e = entry(sender) { controller.reinsert(e) } }

    @objc func openSettings() {
        if settingsWindow == nil {
            let model = AppModel(controller: controller)
            model.openRecorder = { [weak self] in self?.openRecorder() }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: MainView(m: model))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            // Developer tool, kept off the screen: Option-Command-R records eval lines.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.modifierFlags.contains([.command, .option]), e.charactersIgnoringModifiers == "r" { self?.openRecorder(); return nil }
                return e
            }
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openRecorder() {
        let rec = recorder ?? EvalRecorder()
        recorder = rec
        if recorderWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Murmur: record eval set"
            w.contentView = NSHostingView(rootView: EvalRecorderView(rec: rec, keyLabel: controller.settings.dictationKey.label))
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.audioSink = nil }
            }
            recorderWindow = w
        }
        // While the window is open, dictation records eval lines instead of inserting text.
        controller.audioSink = { [weak rec] samples in rec?.save(samples) }
        NSApp.activate()
        recorderWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { snapshot(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
