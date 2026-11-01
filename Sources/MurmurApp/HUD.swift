import AppKit
import SwiftUI

/// The small recording pill at the bottom of the screen: live input level while
/// recording, a travelling wave while processing, a short message on refusal or error.
@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable { case hidden, recording(handsFree: Bool, command: Bool, control: Bool = false), processing, message(String) }
    static let barCount = 14
    @Published var phase: Phase = .hidden
    @Published var levels: [CGFloat] = HUDModel.flat

    static var flat: [CGFloat] { Array(repeating: 0.05, count: barCount) }

    var isRecording: Bool { if case .recording = phase { true } else { false } }

    func push(db: Float) {
        // -60 dBFS is silence, -15 is loud speech.
        let v = CGFloat(max(0.05, min(1, (db + 60) / 45)))
        levels.removeFirst()
        levels.append(v)
    }
}

/// The panel is larger than any pill and transparent; the pill sits at its bottom center and
/// changes size inside it, so the window never moves or resizes while it is on screen.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.phase != .hidden {
                pill
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, HUDController.pillInset)
        .frame(width: HUDController.size.width, height: HUDController.size.height, alignment: .bottom)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.phase)
        .environment(\.colorScheme, .dark)
    }

    private var barTint: Color {
        switch model.phase {
        case .recording(_, true, _): HUDColor.rewrite
        case .recording(_, _, true): HUDColor.control
        case .processing: HUDColor.processing
        default: .white
        }
    }

    private var pill: some View {
        // Plain `if`s, not a `switch`: each element keeps its identity across phases, so the bars
        // stay put from recording into processing and the tags slide in and out around them.
        HStack(spacing: Space.s) {
            if case .recording(let handsFree, let command, let control) = model.phase {
                if command { Tag(symbol: "wand.and.sparkles", text: "Rewrite", tint: HUDColor.rewrite).transition(.opacity) }
                else if control { Tag(symbol: "command", text: "Control", tint: HUDColor.control).transition(.opacity) }
                else { RecordingMark(handsFree: handsFree).transition(.scale.combined(with: .opacity)) }
            }
            if model.phase == .processing || model.isRecording {
                LevelBars(levels: model.levels, processing: model.phase == .processing, tint: barTint)
            }
            if case .recording(true, true, _) = model.phase {
                LockMark(tint: HUDColor.rewrite).transition(.opacity)
            }
            if case .recording(true, false, true) = model.phase {
                LockMark(tint: HUDColor.control).transition(.opacity)
            }
            if case .message(let s) = model.phase {
                Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: HUDController.size.width - 3 * Space.xl)
                    .padding(.horizontal, Space.xs)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.m)
        .frame(height: HUDController.pillHeight)
        .background {
            Capsule().fill(Color(white: 0.08).opacity(0.88))
            Capsule().fill(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .fixedSize()
    }
}

enum HUDColor {
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)
    /// The icon's caret: Rewrite (command mode) is the warm state.
    static let rewrite = Color(red: 1.0, green: 0.69, blue: 0.31)
    /// Voice control: a cool state, so it never reads as dictation about to type.
    static let control = Color(red: 0.42, green: 0.74, blue: 1.0)
    /// The text is being written: the same bars, dimmed, so it never reads as another mode.
    static let processing = Color.white.opacity(0.55)
}

/// The pulsing dot while holding; the same slot shows a lock once hands-free, so the pill
/// keeps its width when fn+space or a double tap locks the recording.
private struct RecordingMark: View {
    let handsFree: Bool
    var body: some View {
        ZStack {
            RecordingDot().opacity(handsFree ? 0 : 1).scaleEffect(handsFree ? 0.4 : 1)
            LockMark(tint: HUDColor.recording).opacity(handsFree ? 1 : 0).scaleEffect(handsFree ? 1 : 0.4)
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(handsFree ? "Recording hands-free" : "Recording")
    }
}

private struct LockMark: View {
    let tint: Color
    var body: some View {
        Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            .frame(width: 12, height: 12)
    }
}

private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle().fill(HUDColor.recording)
            .frame(width: 8, height: 8)
            .background(Circle().fill(HUDColor.recording.opacity(0.35)).scaleEffect(pulse ? 2.1 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

private struct Tag: View {
    let symbol: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.16)))
        .fixedSize()
    }
}

/// Live level while recording; while processing the same bars carry a slow wave, so the
/// change from one to the other is a morph rather than a swap.
private struct LevelBars: View {
    let levels: [CGFloat]
    let processing: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !processing || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<levels.count, id: \.self) { i in
                    Capsule().fill(tint.opacity(0.95))
                        .frame(width: 3, height: 4 + height(i, t) * 16)
                }
            }
            .frame(height: 20)
        }
        .animation(processing ? nil : .linear(duration: 0.06), value: levels)
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        guard processing else { return levels[i] }
        if reduceMotion { return 0.3 }
        let wave = sin(t * 5 - Double(i) * 0.55)
        return CGFloat(0.18 + 0.22 * (wave + 1) / 2)
    }
}

@MainActor
final class HUDController {
    static let size = NSSize(width: 520, height: 84)
    static let pillHeight: CGFloat = 34
    /// Room under the pill for its shadow inside the panel.
    static let pillInset: CGFloat = 16

    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = [] // the pill's size never resizes the panel
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ phase: HUDModel.Phase) {
        hideTask?.cancel()
        orderOutTask?.cancel()
        let wasOnScreen = panel.isVisible && model.phase != .hidden
        // A recording that continues (fn, then space for hands-free) keeps its bars.
        if case .recording = phase, !model.isRecording { model.levels = HUDModel.flat }
        if !wasOnScreen {
            position()
            panel.orderFrontRegardless()
            panel.displayIfNeeded() // draw the empty state first, so the pill animates in
        }
        model.phase = phase
    }

    /// Show a message, then hide, or return to the phase `then` gives (voice control flashes what
    /// it did while hands-free listening goes on).
    func flash(_ message: String, seconds: Double = 1.6, then next: (@MainActor () -> HUDModel.Phase?)? = nil) {
        show(.message(message))
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if let phase = next?() { self.show(phase) } else { self.hide() }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard model.phase != .hidden else { return }
        model.phase = .hidden
        // Let the pill fade out, then take the panel off screen.
        orderOutTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, self.model.phase == .hidden { self.panel.orderOut(nil) }
        }
    }

    private func position() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        // The pill's bottom edge sits 24 pt above the Dock or screen edge.
        panel.setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.minY + 24 - Self.pillInset,
                              width: Self.size.width, height: Self.size.height), display: false)
    }
}
