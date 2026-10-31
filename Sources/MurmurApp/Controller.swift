import AppKit
import ApplicationServices
import MurmurASR
import MurmurCleanup
import MurmurCore
import os

/// One dictation from key down to inserted text, and everything it records.
@MainActor
final class DictationController {
    private(set) var settings: MurmurSettings
    private(set) var status = "Loading models"
    private(set) var ready = false
    /// When the warm mic closes, nil while closed (for status.json).
    private(set) var micOpenUntil: Date?
    var onStatusChange: (() -> Void)?

    private var recognizer: (any Recognizer)?
    private var cleaner: any Cleaner = PassthroughCleaner()
    private var pipeline: CleanupPipeline
    private let capture = AudioCapture()
    let hud = HUDController()
    private let inserter = Inserter()
    let tap = HotkeyTap()
    private var machines: [HotkeyTap.Role: HotkeyStateMachine] = [:]
    let history = HistoryStore()
    let corpus = CorpusStore()
    private let timingLog = TimingLog(url: MurmurPaths.timings)

    // The dictation in flight.
    private var role: HotkeyTap.Role?
    private var session: SegmentedSession?
    private var feed: AsyncStream<[Float]>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var focusTask: Task<FocusSnapshot, Never>?
    private var timings: DictationTimings?
    private var chunker: ChunkedCleanup?
    private var handsFree = false
    /// Dictations recorded and still being recognized, cleaned or inserted. A new one may start
    /// meanwhile; insertions keep their order through `lastProcessing`.
    private var processing = 0
    private var lastProcessing: Task<Void, Never>?
    private let keyLog = Logger(subsystem: "com.cjhorning.murmur", category: "hotkey")
    /// Dictation key timing for the log (never content): last key down and last tap's key up.
    private var keyDownAt: Double?
    private var lastKeyUpAt: Double?
    /// Spelling fixes the user made to inserted text, waiting to be accepted or dismissed.
    private(set) var proposals: [CorrectionDetector.Proposal] = []
    var onProposalsChange: (() -> Void)?
    private var watchTask: Task<Void, Never>?
    /// When set (eval recording mode), finished audio goes here instead of the pipeline.
    var audioSink: (([Float]) -> Void)?

    init() {
        settings = MurmurSettings.load()
        let (dict, snippets) = DictionaryFile.load()
        pipeline = CleanupPipeline(dictionary: dict, snippets: snippets)
        for r in [HotkeyTap.Role.dictation, .command] {
            machines[r] = HotkeyStateMachine(tapMs: Double(settings.tapMs), doubleTapMs: Double(settings.doubleTapMs))
        }
    }

    func setStatus(_ s: String) {
        status = s
        onStatusChange?()
    }

    /// Apply saved settings: keys take effect now; a changed model reloads.
    func update(_ new: MurmurSettings) {
        let reload = new.recognizer != settings.recognizer || new.cleaner != settings.cleaner
        if new.microphone != settings.microphone { capture.preference = new.microphone; capture.rebuild() }
        capture.warmSeconds = new.warmMicMinutes * 60
        settings = new
        tap.keys = tapKeys()
        for r in [HotkeyTap.Role.dictation, .command] {
            machines[r] = HotkeyStateMachine(tapMs: Double(settings.tapMs), doubleTapMs: Double(settings.doubleTapMs))
        }
        if reload {
            ready = false
            Task { await loadModels() }
        }
    }

    // MARK: Startup

    func loadModels() async {
        capture.preference = settings.microphone
        capture.warmSeconds = settings.warmMicMinutes * 60
        capture.onWarmChange = { [weak self] until in
            self?.micOpenUntil = until
            self?.onStatusChange?()
        }
        capture.prepare()
        corpus.purge()
        do {
            let rec = try RecognizerStacks.make(settings.recognizer)
            setStatus("Loading \(rec.name)")
            try await rec.load()
            try await rec.setVocabulary(pipeline.dictionary.biasingTerms)
            recognizer = rec
            let c = try CleanerStacks.make(settings.cleaner)
            if !(c is PassthroughCleaner) { setStatus("Loading \(c.name)") }
            try await c.load()
            cleaner = c
            ready = true
            setStatus("Ready: \(rec.name), cleanup \(c.name)")
        } catch {
            setStatus("Model load failed: \(error)")
        }
        history.purge(olderThanDays: settings.historyDays)
    }

    private func tapKeys() -> [(HotkeyChoice, HotkeyTap.Role)] {
        var keys = [(settings.dictationKey, HotkeyTap.Role.dictation)]
        if let k = settings.rewriteKey, k != settings.dictationKey { keys.append((k, .command)) }
        if settings.shadowMode && settings.dictationKey != .fn { keys.append((.fn, .shadow)) }
        return keys
    }

    func installTap() -> Bool {
        tap.keys = tapKeys()
        tap.isRecording = { [weak self] in self?.role != nil }
        tap.handler = { [weak self] role, event in
            MainActor.assumeIsolated { self?.handle(role, event) ?? false }
        }
        return tap.install()
    }

    // MARK: Key events

    private func handle(_ r: HotkeyTap.Role, _ e: HotkeyStateMachine.Event) -> Bool {
        if r == .shadow { handleShadow(e); return false }
        guard var m = machines[r] else { return false }
        // Only one role records at a time; the other key's events are ignored meanwhile.
        if let active = role, active != r, case .keyDown = e { return false }
        let actions = m.handle(e)
        machines[r] = m
        logKey(e, actions)
        for a in actions {
            switch a {
            case .start: start(r, keyDownMs: e.ms)
            case .enterHandsFree:
                // The first tap's start can fail (secure field, still loading): nothing to keep going.
                guard role != nil else { machines[r] = freshMachine(); return false }
                handsFree = true; timings?.hotkeyMode = "handsFree"; hud.show(.recording(handsFree: true, command: r == .command))
            case .stopAndProcess: stop(keyUpMs: e.ms)
            case .cancel: cancel()
            }
        }
        return e == .escape && !actions.isEmpty
    }

    private func freshMachine() -> HotkeyStateMachine {
        HotkeyStateMachine(tapMs: Double(settings.tapMs), doubleTapMs: Double(settings.doubleTapMs))
    }

    /// Press and gap lengths and what they did, so a missed double tap can be read back from
    /// `log show --predicate 'subsystem == "com.cjhorning.murmur" && category == "hotkey"'`.
    private func logKey(_ e: HotkeyStateMachine.Event, _ actions: [HotkeyStateMachine.Action]) {
        let did = actions.map { "\($0)" }.joined(separator: ",")
        switch e {
        case .keyDown(let t):
            let gap = lastKeyUpAt.map { String(format: "%.0f", t - $0) } ?? "-"
            keyDownAt = t
            keyLog.notice("down, gap since last up \(gap, privacy: .public) ms: \(did, privacy: .public)")
        case .keyUp(let t):
            let held = keyDownAt.map { String(format: "%.0f", t - $0) } ?? "-"
            lastKeyUpAt = t
            keyLog.notice("up, held \(held, privacy: .public) ms: \(did, privacy: .public)")
        default:
            if !actions.isEmpty { keyLog.notice("\(String(describing: e), privacy: .public): \(did, privacy: .public)") }
        }
    }

    private func start(_ r: HotkeyTap.Role, keyDownMs: Double?) {
        guard role == nil else { return }
        guard ready, let recognizer else { hud.flash("Murmur is still loading"); return }
        let keyDown = keyDownMs.map { UInt64($0 * 1e6) } ?? monotonicNanos()
        // Never record into a password field: checked before the mic opens.
        let (el, _) = Focus.focusedElement()
        if Focus.isSecure(el) {
            Sounds.play(Sounds.error, enabled: settings.sounds)
            hud.flash("Secure field: not recording")
            machines[r] = freshMachine()
            return
        }
        var t = DictationTimings(recognizer: recognizer.name, cleaner: cleaner.name)
        t.hotkeyMode = "hold"
        t.mark(.keyDown, at: keyDown)
        timings = t
        role = r
        handsFree = false
        let s = SegmentedSession(recognizer: recognizer)
        session = s
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        feed = cont
        feedTask = Task.detached { for await chunk in stream { await s.append(chunk) } }
        capture.onSamples = { cont.yield($0) }
        capture.onCaptureStarted = { [weak self] at in
            DispatchQueue.main.async { self?.timings?.mark(.captureStarted, at: at) }
        }
        capture.onAudioLive = { [weak self] at in
            DispatchQueue.main.async { self?.timings?.mark(.audioLive, at: at) }
        }
        capture.onLevel = { [weak self] db in
            DispatchQueue.main.async { self?.hud.model.push(db: db) }
        }
        timings?.mark(.micOpening)
        do {
            try capture.start()
        } catch {
            role = nil
            hud.flash("Microphone unavailable")
            return
        }
        timings?.micWarm = capture.startedWarm
        Sounds.play(Sounds.start, enabled: settings.sounds)
        hud.show(.recording(handsFree: false, command: r == .command))
        let focus = Task.detached { Focus.snapshot() }
        focusTask = focus
        chunker = nil
        if r == .dictation, audioSink == nil, !(cleaner is PassthroughCleaner), settings.cleanupChunkWords > 0 {
            // Long dictations clean finished sentences while the user is still talking.
            let overrides = settings.styleOverrides
            var config = ChunkedCleanup.Config()
            config.minWords = settings.cleanupChunkWords
            config.maxWords = 3 * settings.cleanupChunkWords
            let c = ChunkedCleanup(pipeline: pipeline, cleaner: cleaner, config: config) {
                Self.request(raw: "", focus: await focus.value, styleOverrides: overrides)
            }
            chunker = c
            Task { await s.setOnSegment { await c.add($0) } }
        }
        // No audio 1.5 s after the key (AirPods take ~1 s to switch to the mic): rebuild once.
        let token = t.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard self.role != nil, self.timings?.id == token, self.timings?.stamps[.captureStarted] == nil else { return }
            self.capture.rebuild()
            self.capture.onSamples = { cont.yield($0) }
            self.capture.onCaptureStarted = { [weak self] at in DispatchQueue.main.async { self?.timings?.mark(.captureStarted, at: at) } }
            self.capture.onAudioLive = { [weak self] at in DispatchQueue.main.async { self?.timings?.mark(.audioLive, at: at) } }
            self.capture.onLevel = { [weak self] db in DispatchQueue.main.async { self?.hud.model.push(db: db) } }
            do { try self.capture.start(); self.timings?.note = "mic restarted" } catch { self.hud.flash("Microphone unavailable") }
        }
    }

    nonisolated static func request(raw: String, focus: FocusSnapshot, styleOverrides: [String: AppStyle]) -> CleanupRequest {
        let style = AppStyle.resolve(bundleID: focus.bundleID, url: focus.url, overrides: styleOverrides)
        return CleanupRequest(raw: raw, mode: .dictation, style: style, appName: focus.appName,
                              textBefore: String(focus.textBefore.suffix(400)), screenTerms: focus.contextTerms)
    }

    private func cancel() {
        guard role != nil else { return }
        capture.stop()
        feed?.finish()
        role = nil
        session = nil
        chunker = nil
        timings = nil
        if processing > 0 { hud.show(.processing) } else { hud.hide() }
    }

    private func stop(keyUpMs: Double?) {
        guard let r = role, let session, var t = timings else { return }
        t.mark(.keyUp, at: keyUpMs.map { UInt64($0 * 1e6) } ?? monotonicNanos())
        capture.stop()
        feed?.finish()
        role = nil
        processing += 1
        Sounds.play(Sounds.stop, enabled: settings.sounds)
        hud.show(.processing)
        let feedTask = self.feedTask
        let focusTask = self.focusTask
        let chunker = self.chunker
        self.chunker = nil
        let previous = lastProcessing
        let sink = audioSink
        lastProcessing = Task { @MainActor in
            defer { self.processing -= 1 }
            await feedTask?.value
            if let sink {
                sink(await session.audio())
                processingDone()
                return
            }
            t.audioSeconds = Double(await session.sampleCount) / 16_000
            let parts: [String]
            do { parts = try await session.finishParts() } catch {
                if role == nil { hud.flash("Recognition failed") }
                return
            }
            let raw = SegmentedSession.join(parts)
            t.mark(.asrFinal)
            let focus = await focusTask?.value ?? FocusSnapshot()
            t.app = focus.bundleID
            t.mic = capture.deviceKind
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                t.note = t.audioSeconds < 0.2 ? "no audio" : "empty"
                timingLog.append(t)
                if t.audioSeconds >= 0.5 {
                    // Kept so quiet or whispered speech that recognized as nothing can be studied.
                    let record = CorpusRecord(id: t.id, at: t.wallStart, app: focus.bundleID, style: "", seconds: t.audioSeconds,
                                              raw: "", inserted: "", before: "")
                    let corpus = self.corpus, samples = await session.audio()
                    Task.detached { try? corpus.save(record, samples: samples) }
                }
                if role == nil { hud.flash(t.audioSeconds < 0.2 ? "No audio from the microphone" : "Heard nothing: speak up a little") }
                return
            }
            await finish(raw: raw, parts: parts, chunker: chunker, role: r, focus: focus, timings: t,
                         samples: await session.audio(), after: previous)
        }
    }

    /// The HUD after a dictation is done: a newer recording keeps its HUD, another dictation
    /// still processing keeps the processing bars.
    private func processingDone() {
        guard role == nil else { return }
        if processing > 1 { hud.show(.processing) } else { hud.hide() }
    }

    private func finish(raw: String, parts: [String], chunker: ChunkedCleanup?, role r: HotkeyTap.Role, focus: FocusSnapshot,
                        timings: DictationTimings, samples: [Float], after previous: Task<Void, Never>?) async {
        var t = timings
        let mode: CleanupRequest.Mode = r == .command ? .command(selection: focus.selectedText) : .dictation
        if case .command(let sel) = mode {
            // Without a model the "rewrite" would paste the instruction over the selection.
            guard cleaner is MLXCleaner else { hud.flash("Commands need a cleanup model"); return }
            guard !sel.isEmpty else { hud.flash("Select text first for a command"); return }
        }
        let style = AppStyle.resolve(bundleID: focus.bundleID, url: focus.url, overrides: settings.styleOverrides)
        let req = CleanupRequest(raw: raw, mode: mode, style: style, appName: focus.appName,
                                 textBefore: String(focus.textBefore.suffix(400)), screenTerms: focus.contextTerms)
        let firstToken = FirstTokenMark()
        let result: CleanupPipeline.Result
        if let chunker, case .dictation = mode {
            result = await chunker.finish(parts: parts) { firstToken.mark() }
            let n = await chunker.chunksStarted
            if n > 0 { t.cleanupChunks = n }
        } else {
            do {
                result = try await pipeline.run(req, cleaner: cleaner) { firstToken.mark() }
            } catch {
                result = .init(text: CleanupPipeline.tidy(raw, style: style), usedModel: false, fellBack: "\(error)")
            }
        }
        if let ft = firstToken.at { t.mark(.cleanupFirstToken, at: ft) }
        t.mark(.cleanupDone)
        if !result.usedModel { t.note = "fast path" }
        if let fb = result.fellBack { t.note = "fell back: " + (settings.debugLogging ? fb : "hard check") }

        var text = result.text
        // Like Wispr: a trailing space so the next dictation continues the sentence.
        if case .dictation = mode, style != .terminal, !text.hasSuffix("\n") { text += " " }
        // An earlier dictation still finishing inserts first.
        await previous?.value
        let outcome = await inserter.insert(text, into: focus, overrides: settings.insertionOverrides)
        if let at = outcome.insertedAt { t.mark(.inserted, at: at) }
        if !outcome.ok {
            // Leave the text on the clipboard to paste by hand.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if role == nil { hud.flash(outcome.method == .none ? "Not inserted (secure field)" : "Copied: paste with ⌘V") }
        } else {
            processingDone()
        }
        timingLog.append(t)
        // Keep the dictation for improving Murmur (private, 90 days).
        let record = CorpusRecord(id: t.id, at: t.wallStart, app: focus.bundleID, style: style.rawValue, seconds: t.audioSeconds,
                                  raw: raw, inserted: text, before: String(focus.textBefore.suffix(600)))
        let corpus = self.corpus
        Task.detached { try? corpus.save(record, samples: samples) }
        if outcome.ok, case .dictation = mode, let el = focus.element {
            watchForCorrections(el, inserted: text, record: record)
        }
        try? history.append(HistoryEntry(app: focus.bundleID, raw: raw, text: text,
                                          mode: r == .command ? "command" : "dictation", inserted: outcome.ok))
    }

    // MARK: Shadow mode

    private var shadow: (session: SegmentedSession, feed: AsyncStream<[Float]>.Continuation, task: Task<Void, Never>,
                         started: Date, keyDown: Double, focus: Task<FocusSnapshot, Never>)?

    /// While Wispr's Fn is held, record silently and run Murmur's pipeline without inserting.
    private func handleShadow(_ e: HotkeyStateMachine.Event) {
        switch e {
        case .keyDown(let t):
            guard settings.shadowMode, ready, role == nil, processing == 0, shadow == nil, let recognizer else { return }
            let (el, _) = Focus.focusedElement()
            if Focus.isSecure(el) { return }
            let s = SegmentedSession(recognizer: recognizer)
            let (stream, cont) = AsyncStream<[Float]>.makeStream()
            let task = Task.detached { for await c in stream { await s.append(c) } }
            capture.onSamples = { cont.yield($0) }
            capture.onLevel = nil
            capture.onCaptureStarted = nil
            capture.onAudioLive = nil
            do { try capture.start() } catch { cont.finish(); return }
            shadow = (s, cont, task, Date(), t, Task.detached { Focus.snapshot() })
        case .keyUp(let t):
            guard let sh = shadow else { return }
            shadow = nil
            capture.stop()
            sh.feed.finish()
            // A tap (Wispr's hands-free toggle) is not a dictation.
            guard t - sh.keyDown > 300 else { return }
            let pipeline = self.pipeline, cleaner = self.cleaner, recName = recognizer?.name ?? "?"
            Task { @MainActor in
                await sh.task.value
                let samples = await sh.session.audio()
                let t0 = monotonicNanos()
                guard let raw = try? await sh.session.finish(), !raw.isEmpty else { return }
                let asrMs = Double(monotonicNanos() - t0) / 1e6
                let focus = await sh.focus.value
                let style = AppStyle.resolve(bundleID: focus.bundleID, overrides: settings.styleOverrides)
                let t1 = monotonicNanos()
                let out = (try? await pipeline.run(CleanupRequest(raw: raw, style: style, appName: focus.appName,
                                                                  textBefore: String(focus.textBefore.suffix(400)),
                                                                  screenTerms: focus.contextTerms), cleaner: cleaner) {})?.text ?? raw
                let entry = ShadowEntry(id: UUID().uuidString, startedAt: sh.started, seconds: Double(samples.count) / 16_000,
                                        app: focus.bundleID, raw: raw, output: out, recognizer: recName, cleaner: cleaner.name,
                                        asrTailMs: asrMs, cleanupMs: Double(monotonicNanos() - t1) / 1e6)
                try? entry.save(samples: samples)
            }
        case .otherKey:
            // Fn used as a modifier (Fn+arrow): not speech.
            guard let sh = shadow else { return }
            shadow = nil
            capture.stop()
            sh.feed.finish()
        case .escape, .handsFreeKey:
            break
        }
    }

    // MARK: Correction learning

    /// Read the field shortly after insertion, then every 2 s for 30 s; spelling fixes of
    /// inserted words become proposals. Nothing is added to the dictionary until the user accepts.
    private func watchForCorrections(_ el: AXUIElement, inserted: String, record: CorpusRecord) {
        watchTask?.cancel()
        watchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let base: String = Focus.attr(el, kAXValueAttribute), base.count < 20_000 else { return }
            var last = base
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let now: String = Focus.attr(el, kAXValueAttribute) else { return }
                if now == last { continue }
                last = now
                for p in CorrectionDetector.proposals(inserted: inserted, fieldAfterInsert: base, fieldLater: now)
                where !proposals.contains(p) && !pipeline.dictionary.entries.contains(where: { $0.term == p.corrected }) {
                    proposals.append(p)
                    onProposalsChange?()
                    hud.flash("Learned \u{201C}\(p.corrected)\u{201D}. Open Murmur to add it.", seconds: 2.5)
                }
            }
            corpus.update(id: record.id, at: record.at, later: last)
        }
    }

    func accept(_ p: CorrectionDetector.Proposal) {
        proposals.removeAll { $0 == p }
        var (dict, snippets) = DictionaryFile.load()
        dict.merge([DictionaryEntry(term: p.corrected, sounds: [p.heard], source: .learned)])
        try? DictionaryFile.save(dict, snippets)
        pipeline.dictionary = dict
        Task { try? await recognizer?.setVocabulary(dict.biasingTerms) }
        if let m = cleaner as? MLXCleaner { m.setDictionary(dict.biasingTerms) }
    }

    func dismiss(_ p: CorrectionDetector.Proposal) { proposals.removeAll { $0 == p } }

    /// Pick up dictionary and snippet edits made in the window.
    func reloadDictionary() {
        let (dict, snippets) = DictionaryFile.load()
        pipeline.dictionary = dict
        pipeline.snippets = snippets
        Task { try? await recognizer?.setVocabulary(dict.biasingTerms) }
        if let m = cleaner as? MLXCleaner { m.setDictionary(dict.biasingTerms) }
    }

    // MARK: History actions

    func copy(_ e: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text, forType: .string)
    }

    func reinsert(_ e: HistoryEntry) {
        Task { @MainActor in
            // Give the menu time to close and focus to return to the previous app.
            try? await Task.sleep(for: .milliseconds(250))
            let focus = Focus.snapshot()
            _ = await inserter.insert(e.text, into: focus, overrides: settings.insertionOverrides)
        }
    }
}

/// Thread-safe one-shot timestamp for the first cleanup token.
final class FirstTokenMark: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var at: UInt64?
    func mark() {
        lock.lock(); defer { lock.unlock() }
        if at == nil { at = monotonicNanos() }
    }
}

extension HotkeyStateMachine.Event {
    var ms: Double? {
        switch self {
        case .keyDown(let m), .keyUp(let m), .otherKey(let m), .handsFreeKey(let m): return m
        case .escape: return nil
        }
    }
}
