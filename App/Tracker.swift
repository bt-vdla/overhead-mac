import Foundation
import AppKit
import CoreLocation
import IOKit.ps
import SwiftData
import OverheadCore

/// The aircraft the panel is showing.
struct Flight {
    let aircraft: Aircraft
    let motion: Motion
    let route: Route?
}

/// Polls the feed, keeps every aircraft's motion, decides what's overhead and logs each pass.
@MainActor @Observable final class Tracker {
    static let shared = Tracker()
    nonisolated static let support = URL.applicationSupportDirectory.appending(path: "Overhead")
    nonisolated static let recordings = support.appending(path: "Recordings")

    private(set) var motions: [String: Motion] = [:]
    private(set) var info: [String: Aircraft] = [:]
    private(set) var presenter = Presenter()
    private(set) var observer: Observer?
    /// One line for the menu when something isn't normal: replaying, waiting for location, offline.
    private(set) var status: String?
    var paused = false { didSet { restart() } }

    private var routes: [String: RouteEntry] = Tracker.loadRoutes()
    private var replay: Replay?

    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var lookingUp: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var collapse: Task<Void, Never>?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var passes: [String: Passover] = [:]
    @ObservationIgnored private let location = Location()

    var flight: Flight? {
        guard let hex = presenter.hex, let motion = motions[hex], let aircraft = info[hex] else { return nil }
        return Flight(aircraft: aircraft, motion: motion, route: aircraft.callsign.flatMap(route(for:)))
    }

    func route(for callsign: String) -> Route? { replay?.routes[callsign] ?? routes[callsign]?.route }

    // MARK: Loop

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Tracker.shared.sleep(true) } }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Tracker.shared.sleep(false) } }
        }
        location.start()
        restart()
    }

    private func sleep(_ asleep: Bool) {
        guard asleep != self.asleep else { return }
        self.asleep = asleep
        restart()
    }

    private var source: Source { Source(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .live }

    /// Starts over from nothing: on a source change, pause, wake, or settings change. Polls right away.
    func restart() {
        loop?.cancel()
        reset()
        recorder = nil
        replay = nil
        status = nil
        let source = self.source
        switch source {
        case .synthetic: replay = .flyover(over: liveObserver ?? Observer(lat: 51.4700, lon: -0.4543))
        case .replay:
            replay = latestRecording()
            if replay == nil { status = "No recordings yet"; return }
        case .live, .record: break
        }
        guard !asleep, !paused else { return }
        loop = Task {
            while !Task.isCancelled {
                await poll(source)
                try? await Task.sleep(for: .seconds(interval(source)))
            }
        }
    }

    /// 10 s on power; backs off on battery. Recording and replay hold 10 s so recordings play back at the speed they were made.
    private func interval(_ source: Source) -> Double {
        guard source == .live else { return 10 }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 60 }
        return onBattery ? 30 : 10
    }

    private var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    private var liveObserver: Observer? {
        let d = UserDefaults.standard
        if d.bool(forKey: "manualLocation") {
            return Observer(lat: d.object(forKey: "manualLat") as? Double ?? 51.4700, lon: d.object(forKey: "manualLon") as? Double ?? -0.4543)
        }
        return location.last
    }

    private func poll(_ source: Source) async {
        let data: Data, o: Observer
        if var r = replay {
            let frame = r.next()
            replay = r
            if frame.wrapped { reset() }
            data = frame.data
            o = r.observer
        } else {
            guard let live = liveObserver else { status = "Waiting for your location"; return }
            let url = URL(string: String(format: "https://api.adsb.lol/v2/point/%.4f/%.4f/50", live.lat, live.lon))!
            do {
                let (d, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                data = d
                o = live
            } catch {
                status = "Can't reach adsb.lol"
                return
            }
            if source == .record {
                if recorder == nil {
                    let name = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")  // sorts by time
                    recorder = try? Recorder(directory: Self.recordings.appending(path: name), observer: o)
                }
                try? recorder?.append(data)
            }
        }
        guard let aircraft = try? Aircraft.decode(data) else { status = "Couldn't read the flight data"; return }
        status = source == .live ? nil : source.title
        ingest(aircraft, from: o, at: .now)
    }

    private func reset() {
        collapse?.cancel()
        motions = [:]
        info = [:]
        presenter = Presenter()
        passes = [:]
    }

    // MARK: Decide

    private func ingest(_ aircraft: [Aircraft], from o: Observer, at now: Date) {
        observer = o
        for a in aircraft {
            guard let fix = a.fix(receivedAt: now) else { continue }
            info[a.hex] = a
            if motions[a.hex] == nil { motions[a.hex] = Motion(fix) } else { motions[a.hex]?.update(fix, at: now) }
        }
        motions = motions.filter { now.timeIntervalSince($0.value.fix.time) < Fix.maxCoast }
        info = info.filter { motions[$0.key] != nil }

        let candidates = motions.map { hex, m in
            Candidate(hex: hex, look: look(from: o, to: m.fix.position(at: now)), triggered: Pass.triggers(m.fix, from: o, at: now))
        }
        if presenter.update(candidates, at: now) {
            Thop.shared.play()
            collapse?.cancel()
            collapse = Task {
                try? await Task.sleep(for: .seconds(Presenter.openFor))
                if !Task.isCancelled { presenter.tick(at: .now) }
            }
        }
        if let callsign = flight?.aircraft.callsign { lookUp(callsign) }
        log(candidates, from: o, at: now)
    }

    /// One `Passover` per aircraft per pass. It starts when the aircraft triggers and ends once it sinks below 15°
    /// or disappears from the feed.
    private func log(_ candidates: [Candidate], from o: Observer, at now: Date) {
        let context = History.container.mainContext
        for c in candidates {
            let a = info[c.hex]
            if passes[c.hex] == nil, c.triggered {
                let p = Passover(time: now, hex: c.hex, callsign: a?.callsign, type: a?.t, peakElevation: c.look.elevation)
                context.insert(p)
                passes[c.hex] = p
                if let callsign = a?.callsign { lookUp(callsign) }
            }
            guard let p = passes[c.hex], let m = motions[c.hex] else { continue }
            guard c.triggered || c.look.elevation >= Pass.keepElevation else { passes[c.hex] = nil; continue }
            // Samples the next 10 s of path too: a 10 s poll alone can miss the top of a fast, low pass by 20°.
            let peak = (0...10).map { look(from: o, to: m.fix.position(at: now + Double($0))).elevation }.max() ?? 0
            p.peakElevation = max(p.peakElevation, peak)
            if p.route == nil, let callsign = p.callsign, let r = route(for: callsign) {
                p.route = "\(r.origin.code) → \(r.destination.code)"
            }
        }
        passes = passes.filter { motions[$0.key] != nil }
        try? context.save()
    }

    // MARK: Routes

    struct RouteEntry: Codable {
        var route: Route?
        var expires: Date
    }

    nonisolated private static let routesFile = support.appending(path: "routes.json")

    nonisolated private static func loadRoutes() -> [String: RouteEntry] {
        let all = (try? JSONDecoder().decode([String: RouteEntry].self, from: Data(contentsOf: routesFile))) ?? [:]
        return all.filter { $0.value.expires > .now }
    }

    /// Asks adsbdb once per callsign. Routes are kept a week. Unknown callsigns are kept a day, so they aren't asked
    /// again every poll. Errors are retried after 5 minutes.
    private func lookUp(_ callsign: String) {
        if replay?.routes[callsign] != nil { return }
        if let e = routes[callsign], e.expires > .now { return }
        guard lookingUp.insert(callsign).inserted,
              let path = callsign.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(path)") else { return }
        Task {
            defer { lookingUp.remove(callsign) }
            var entry = RouteEntry(route: nil, expires: .now + 300)
            if let reply = try? await URLSession.shared.data(from: url) {
                switch (reply.1 as? HTTPURLResponse)?.statusCode {
                case 200:
                    let route = Route.decode(reply.0)
                    entry = RouteEntry(route: route, expires: .now + (route == nil ? 86_400 : 7 * 86_400))
                case 404: entry.expires = .now + 86_400
                default: break
                }
            }
            routes[callsign] = entry
            try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            try? JSONEncoder().encode(routes).write(to: Self.routesFile, options: .atomic)
        }
    }

    // MARK: Replay

    private func latestRecording() -> Replay? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.recordings, includingPropertiesForKeys: nil)) ?? []
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.lazy.compactMap { try? Replay(directory: $0) }.first
    }
}

// MARK: - Location

/// CoreLocation at roughly 100 m accuracy. A desk doesn't move, so updates are rare and cheap.
@MainActor final class Location: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var last: Observer?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let o = Observer(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                         alt: l.verticalAccuracy >= 0 ? l.ellipsoidalAltitude : 0)
        // Delegate calls arrive on the thread that made the manager: main.
        MainActor.assumeIsolated { last = o }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
