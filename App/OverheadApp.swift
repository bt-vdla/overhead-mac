import SwiftUI
import SwiftData
import AVFoundation
import OverheadCore

@main
struct OverheadApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("Overhead", systemImage: "airplane") {
            MenuContent(tracker: .shared)
        }
        .modelContainer(History.container)
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Tracker.shared.start()
        PanelController.shared.start()
    }
}

// MARK: - History

/// One aircraft passing overhead.
@Model final class Passover {
    var time: Date
    var hex: String
    var callsign: String?
    /// "LHR → JFK", once adsbdb has answered.
    var route: String?
    var type: String?
    var peakElevation: Double

    init(time: Date, hex: String, callsign: String?, type: String?, peakElevation: Double) {
        self.time = time; self.hex = hex; self.callsign = callsign; self.type = type; self.peakElevation = peakElevation
    }
}

enum History {
    @MainActor static let container: ModelContainer = {
        do { return try ModelContainer(for: Passover.self) } catch { fatalError("History store: \(error)") }
    }()
}

// MARK: - Menu

struct MenuContent: View {
    let tracker: Tracker
    // ponytail: loads every passover to count today's; a FetchDescriptor count when the log reaches tens of thousands.
    @Query(sort: \Passover.time, order: .reverse) private var log: [Passover]
    @AppStorage("source") private var source = Source.live
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let today = log.filter { Calendar.current.isDateInToday($0.time) }
        Text(today.count == 1 ? "1 overhead today" : "\(today.count) overhead today")
        if let last = log.first {
            Text([last.callsign ?? last.hex.uppercased(), last.route, last.time.formatted(.relative(presentation: .named))]
                .compactMap(\.self).joined(separator: " · "))
        }
        if let status = tracker.status { Text(status) }
        Divider()
        Toggle("Pause", isOn: Binding(get: { tracker.paused }, set: { tracker.paused = $0 }))
        Picker("Source", selection: $source) {
            ForEach(Source.allCases, id: \.self) { Text($0.title) }
        }
        .onChange(of: source) { tracker.restart() }
        Divider()
        // An accessory app has to come forward itself, or Settings opens behind everything.
        Button("Settings…") { NSApp.activate(); openSettings() }
            .keyboardShortcut(",")
        Button("Quit Overhead") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum Source: String, CaseIterable {
    case live, record, replay, synthetic
    var title: String {
        switch self {
        case .live: "Live"
        case .record: "Live, Recording"
        case .replay: "Replay Last Recording"
        case .synthetic: "Synthetic Flyover"
        }
    }
}

struct SettingsView: View {
    @AppStorage("manualLocation") private var manual = false
    @AppStorage("manualLat") private var lat = 51.4700
    @AppStorage("manualLon") private var lon = -0.4543
    @AppStorage("sound") private var sound = true

    var body: some View {
        Form {
            Section("Location") {
                Toggle("Set location manually", isOn: $manual)
                TextField("Latitude", value: $lat, format: .number.precision(.fractionLength(4)))
                    .disabled(!manual)
                TextField("Longitude", value: $lon, format: .number.precision(.fractionLength(4)))
                    .disabled(!manual)
            }
            Section {
                Toggle("Play a sound when a flight drops in", isOn: $sound)
            }
            Section("Development") {
                Button("Show Recordings in Finder") {
                    try? FileManager.default.createDirectory(at: Tracker.recordings, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([Tracker.recordings])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onChange(of: manual) { Tracker.shared.restart() }
    }
}

// MARK: - Sound

/// A soft "thop": a 180 Hz sine that drops in pitch and dies away in ~80 ms. It's rendered once,
/// and the engine runs only while it plays, so the audio hardware isn't kept awake.
@MainActor final class Thop {
    static let shared = Thop()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    private var stopping: Task<Void, Never>?

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * 0.12)
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / 48_000
            let pitch = 180 * (1 + 0.6 * exp(-t / 0.012))  // ~290 Hz falling to 180 within ~30 ms
            phase += 2 * .pi * pitch / 48_000
            let attack = min(t / 0.003, 1)  // 3 ms, no click
            out[i] = Float(sin(phase) * attack * exp(-t / 0.022) * 0.18)  // ~80 ms to silence, quiet
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play() {
        guard UserDefaults.standard.object(forKey: "sound") as? Bool ?? true else { return }
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer)
        player.play()
        stopping?.cancel()
        stopping = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { engine.stop() }
        }
    }
}
