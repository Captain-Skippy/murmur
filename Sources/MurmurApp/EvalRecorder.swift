import AppKit
import MurmurCore
import SwiftUI

/// Recording mode for the scripted eval set: shows one line at a time; holding the
/// dictation key records it (through the same capture path as dictation) and saves the
/// WAV with its reference into the private eval set "scripted". Nothing is inserted.
@MainActor
final class EvalRecorder: ObservableObject {
    struct Line: Codable {
        var id: String
        var categories: [String]
        var say: String
        var expected: String
        var app: String?
        var mustContain: [String]?
        var mustNotContain: [String]?
        var mustNotObey: Bool?
        var whisper: Bool?
        var noise: Bool?
    }

    @Published var lines: [Line] = []
    @Published var index = 0
    @Published var recorded = Set<String>()
    @Published var message = "Hold the dictation key and read the line exactly as written, fillers included."
    private var set: EvalSet

    init() {
        // Your own script, when you keep one with your private data, else the one shipped in the app.
        let own = MurmurPaths.eval.appendingPathComponent("script.json")
        let url = FileManager.default.fileExists(atPath: own.path) ? own : Bundle.main.url(forResource: "script", withExtension: "json")
        lines = (try? JSONDecoder().decode([Line].self, from: Data(contentsOf: url ?? URL(fileURLWithPath: "/dev/null")))) ?? []
        set = (try? EvalSet.load("scripted")) ?? EvalSet(name: "scripted", dir: EvalSet.url("scripted"), items: [])
        recorded = Set(set.items.map(\.id))
        index = lines.firstIndex { !recorded.contains($0.id) } ?? 0
    }

    var current: Line? { lines.indices.contains(index) ? lines[index] : nil }

    func save(_ samples: [Float]) {
        guard let line = current else { return }
        guard samples.count > 16_000 / 2 else { message = "Too short; hold the key while you read."; return }
        do {
            try MurmurPaths.ensurePrivate(set.dir.appendingPathComponent("audio"))
            let rel = "audio/\(line.id).wav"
            try AudioFile.write16k(samples, to: set.dir.appendingPathComponent(rel))
            var item = EvalItem(id: line.id, audio: rel, seconds: Double(samples.count) / 16_000, categories: line.categories)
            item.reference = line.say
            item.expectedText = line.expected
            item.app = line.app
            item.recordedAt = Date()
            item.expectation = HardChecks.Expectation(mustContain: line.mustContain ?? [], mustNotContain: line.mustNotContain ?? [],
                                                      mustNotObey: line.mustNotObey ?? false)
            set.items.removeAll { $0.id == line.id }
            set.items.append(item)
            try set.save()
            recorded.insert(line.id)
            message = String(format: "Saved %@ (%.1f s, %.0f dBFS).", line.id, item.seconds, AudioFile.rmsDb(samples))
            if let next = lines.indices.first(where: { $0 > index && !recorded.contains(lines[$0].id) }) { index = next }
        } catch {
            message = "Could not save: \(error)"
        }
    }
}

struct EvalRecorderView: View {
    @ObservedObject var rec: EvalRecorder
    var keyLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Eval recording").font(.headline)
                Spacer()
                Text("\(rec.recorded.count) of \(rec.lines.count) recorded").foregroundStyle(.secondary)
            }
            if let line = rec.current {
                HStack(spacing: 8) {
                    Text(line.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if line.whisper == true { Label("Whisper this one", systemImage: "speaker.wave.1").font(.caption).foregroundStyle(.orange) }
                    if line.noise == true { Label("Play background noise (music or a fan)", systemImage: "waveform").font(.caption).foregroundStyle(.orange) }
                    if rec.recorded.contains(line.id) { Label("Recorded; hold again to replace", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                }
                Text(line.say).font(.title3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No script found in the app bundle.")
            }
            Text("Hold \(keyLabel) and read. \(rec.message)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Previous") { rec.index = max(0, rec.index - 1) }.disabled(rec.index == 0)
                Button("Next") { rec.index = min(rec.lines.count - 1, rec.index + 1) }.disabled(rec.index >= rec.lines.count - 1)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
