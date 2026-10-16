import SwiftUI
import AppKit

// MARK: - Audio window

struct AudioView: View {
    @ObservedObject var engine = CaptureEngine.shared
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: engine.isAudioLive ? "waveform" : "waveform.slash").foregroundStyle(engine.isAudioLive ? .green : .secondary)
                Text(engine.audioDevice?.localizedName ?? "No audio input").font(.headline)
                Spacer()
                Text(prefs.audioFormat.label).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                let levels = engine.audioLevels.isEmpty ? [Float](repeating: -80, count: prefs.audioFormat.channels) : engine.audioLevels
                ForEach(Array(levels.enumerated()), id: \.offset) { i, db in
                    HStack {
                        Text(levels.count == 1 ? "M" : (i == 0 ? "L" : i == 1 ? "R" : "\(i + 1)")).font(.caption.monospaced()).frame(width: 16)
                        LevelMeter(db: db)
                        Text(String(format: "%.0f dB", db)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Divider()
            Toggle("Monitor audio through the default output", isOn: $prefs.audioMonitorOn)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $prefs.audioMonitorVolume, in: 0...1).disabled(!prefs.audioMonitorOn)
                Image(systemName: "speaker.wave.3.fill")
            }
            Text("Monitoring plays the captured audio on your Mac's output with a small delay. Turn it off if you hear an echo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct LevelMeter: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * frac)
            }
        }
        .frame(height: 12)
        .animation(.linear(duration: 0.07), value: db)
    }
}

// MARK: - Errors window

struct ErrorsView: View {
    @ObservedObject var log = ErrorLog.shared
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            List(log.entries.reversed()) { e in
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.fmt.string(from: e.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text(e.category).font(.caption.bold()).frame(width: 70, alignment: .leading)
                    Text(e.message).font(.caption).textSelection(.enabled)
                    Spacer()
                    if e.code != 0 { Text("\(e.code)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            Divider()
            HStack {
                Text("\(log.entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
            }.padding(8)
        }
        .frame(minWidth: 520, minHeight: 240)
    }
}

// MARK: - Time-limited recording sheet

struct TimeLimitSheet: View {
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int
    let onStart: (Int) -> Void
    let onCancel: () -> Void

    init(initialSeconds: Int, onStart: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        _hours = State(initialValue: initialSeconds / 3600)
        _minutes = State(initialValue: initialSeconds / 60 % 60)
        _seconds = State(initialValue: initialSeconds % 60)
        self.onStart = onStart; self.onCancel = onCancel
    }
    var total: Int { hours * 3600 + minutes * 60 + seconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture Time Limit").font(.headline)
            HStack {
                Text("Limit capture duration to:")
                Stepper(value: $hours, in: 0...99) { Text("\(hours) h").monospacedDigit().frame(width: 40) }
                Stepper(value: $minutes, in: 0...59) { Text("\(minutes) m").monospacedDigit().frame(width: 40) }
                Stepper(value: $seconds, in: 0...59) { Text("\(seconds) s").monospacedDigit().frame(width: 40) }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Start") { onStart(total) }.keyboardShortcut(.defaultAction).disabled(total <= 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Hosting helper

enum PanelWindows {
    static func make<V: View>(title: String, autosave: String, _ view: V, resizable: Bool = true) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(autosave)
        return w
    }
}
