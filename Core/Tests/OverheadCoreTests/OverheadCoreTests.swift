import Foundation
import Testing
@testable import OverheadCore

private let home = Observer(lat: 51.5, lon: -0.1)
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

/// A fix `distance` m from home along `bearing`, at `alt` m, flying `track` at `speed` m/s.
private func fix(bearing: Double, distance: Double, alt: Double, track: Double = 0, speed: Double = 0, climb: Double = 0, at t: Date = t0) -> Fix {
    let p = destination(lat: home.lat, lon: home.lon, bearing: bearing, distance: distance)
    return Fix(lat: p.lat, lon: p.lon, alt: alt, speed: speed, track: track, climb: climb, time: t)
}

struct LookTests {
    @Test func straightUp() {
        let l = look(from: home, to: Position(lat: home.lat, lon: home.lon, alt: 10_000))
        #expect(near(l.elevation, 90, 1e-6))
        #expect(near(l.range, 10_000, 1e-3))
    }

    @Test func fortyFiveDegreesEachWay() {
        // 10 km out, 10 km up: ~45° (curvature and the sphere-vs-ellipsoid ground distance take ~0.1° off).
        for (bearing, compass) in [(0.0, "N"), (90, "E"), (225, "SW")] {
            let l = look(from: home, to: fix(bearing: bearing, distance: 10_000, alt: 10_000).position(at: t0))
            #expect(near(l.elevation, 45, 0.3))
            #expect(near(l.range, 14_142, 40))
            #expect(near(l.azimuth.truncatingRemainder(dividingBy: 360), bearing, 0.2) || near(l.azimuth, 360, 0.2))
            #expect(l.compass == compass)
        }
    }

    @Test func farAwayIsLow() {
        let l = look(from: home, to: fix(bearing: 0, distance: 26_000, alt: 15_000).position(at: t0))
        #expect(near(l.elevation, 29.8, 0.2))
        #expect(near(l.range, 30_056, 50))
        #expect(!Pass.qualifies(l))  // high enough, too far
    }
}

struct MotionTests {
    @Test func deadReckonsAlongTrack() {
        let f = Fix(lat: home.lat, lon: home.lon, alt: 1_000, speed: 100, track: 90, climb: 5, time: t0)
        let p = f.position(at: t0 + 10)
        let l = look(from: Observer(lat: home.lat, lon: home.lon, alt: 1_050), to: p)
        #expect(near(p.alt, 1_050, 1e-9))
        #expect(near(l.range, 1_000, 5))
        #expect(near(l.azimuth, 90, 0.5))
    }

    @Test func staleFixesStopCoasting() {
        let f = Fix(lat: 0, lon: 0, alt: 0, speed: 200, track: 0, time: t0)
        #expect(f.position(at: t0 + 600) == f.position(at: t0 + Fix.maxCoast))
        #expect(f.position(at: t0 - 5) == f.position(at: t0))
    }

    @Test func correctionsGlideNeverTeleport() {
        var m = Motion(fix(bearing: 0, distance: 0, alt: 3_000, track: 0, speed: 200))
        let now = t0 + 10
        let before = m.position(at: now)
        // The new fix says it's 500 m east of the guess and turned 20°.
        let truth = destination(lat: before.lat, lon: before.lon, bearing: 90, distance: 500)
        let new = Fix(lat: truth.lat, lon: truth.lon, alt: 3_100, speed: 200, track: 20, time: now)
        m.update(new, at: now)

        let at0 = m.position(at: now)
        #expect(near(at0.lat, before.lat, 1e-12) && near(at0.lon, before.lon, 1e-12) && near(at0.alt, before.alt, 1e-9))
        #expect(near(at0.track, 0, 1e-9))

        // Small steps only: no frame moves more than a frame's worth of flight plus its share of the 500 m.
        var last = at0
        for i in 1...90 {
            let p = m.position(at: now + Double(i) / 60)
            #expect(look(from: Observer(lat: last.lat, lon: last.lon, alt: last.alt), to: p).range < 30)
            last = p
        }
        #expect(m.position(at: now + Motion.blend) == new.position(at: now + Motion.blend))
    }

    @Test func turnsTheShortWayRound() {
        var m = Motion(Fix(lat: 0, lon: 0, alt: 0, track: 350, time: t0))
        m.update(Fix(lat: 0, lon: 0, alt: 0, track: 10, time: t0), at: t0)
        let mid = m.position(at: t0 + Motion.blend / 2).track
        #expect(near(mid, 0, 1e-6) || near(mid, 360, 1e-6))
    }
}

struct OverheadTests {
    // 3 km up, 25° is reached 6.43 km out.
    @Test func overheadNow() {
        #expect(Pass.triggers(fix(bearing: 0, distance: 0, alt: 3_000), from: home, at: t0))
        #expect(Pass.triggers(fix(bearing: 0, distance: 0, alt: 12_000), from: home, at: t0))
    }

    @Test func predictedWithinTwentySeconds() {
        let close = fix(bearing: 180, distance: 8_934, alt: 3_000, track: 0, speed: 250)  // 18.5° now, 25° in ~11 s
        #expect(!Pass.qualifies(look(from: home, to: close.position(at: t0))))
        #expect(Pass.triggers(close, from: home, at: t0))
        let edge = fix(bearing: 180, distance: 11_309, alt: 3_000, track: 0, speed: 250)  // reaches 25° at 19.5 s
        #expect(Pass.triggers(edge, from: home, at: t0))
        let late = fix(bearing: 180, distance: 11_684, alt: 3_000, track: 0, speed: 250)  // 21 s
        #expect(!Pass.triggers(late, from: home, at: t0))
        let away = fix(bearing: 180, distance: 8_934, alt: 3_000, track: 180, speed: 250)
        #expect(!Pass.triggers(away, from: home, at: t0))
    }
}

struct PresenterTests {
    private func c(_ hex: String, _ el: Double, _ triggered: Bool) -> Candidate {
        Candidate(hex: hex, look: Look(azimuth: 0, elevation: el, range: 5_000), triggered: triggered)
    }

    @Test func dropsOnceThenCollapsesThenLeaves() {
        var p = Presenter()
        #expect(!p.update([c("a", 10, false)], at: t0))
        #expect(p.phase == .hidden)
        #expect(p.update([c("a", 30, true), c("b", 40, true)], at: t0))
        #expect(p.phase == .expanded && p.hex == "b" && p.others == 1)
        #expect(!p.update([c("b", 50, true)], at: t0 + 10))
        p.tick(at: t0 + 59)
        #expect(p.phase == .expanded)
        p.tick(at: t0 + 60)
        #expect(p.phase == .compact)
        #expect(!p.update([c("b", 16, false)], at: t0 + 70))  // below 25° but still above 15°: stays
        #expect(p.phase == .compact && p.hex == "b" && p.others == 0)
        p.update([c("b", 14, false)], at: t0 + 80)
        #expect(p.phase == .hidden && p.hex == nil)
    }

    @Test func untriggeredStrangersDontKeepItOpen() {
        var p = Presenter()
        p.update([c("a", 30, true)], at: t0)
        p.update([c("z", 60, false)], at: t0 + 10)  // high, but never triggered
        #expect(p.phase == .hidden)
    }
}

struct FeedTests {
    @Test func decodesPointResponse() throws {
        let json = """
        {"ac":[
          {"hex":"4ca7b1","type":"adsb_icao","flight":"RYR12AB ","r":"EI-DCL","t":"B738","desc":"BOEING 737-800",
           "alt_baro":9000,"alt_geom":9325,"gs":312.4,"track":271.3,"baro_rate":-640,"lat":51.52,"lon":-0.08,"seen_pos":1.2,"seen":0.4},
          {"hex":"400f01","flight":"BAW1   ","alt_baro":"ground","gs":3,"lat":51.47,"lon":-0.45},
          {"hex":"~2a0001","alt_baro":12000},
          {"hex":"3c6444","alt_baro":34000,"lat":51.6,"lon":-0.2,"seen_pos":75}
        ],"msg":"No error","now":1762650000000,"total":4,"ctime":1762650000123,"ptime":2}
        """
        let ac = try Aircraft.decode(Data(json.utf8))
        #expect(ac.count == 4)
        #expect(ac[0].callsign == "RYR12AB" && ac[0].t == "B738")
        let f = try #require(ac[0].fix(receivedAt: t0))
        #expect(near(f.alt, 9_325 * 0.3048, 1e-9))  // geometric preferred
        #expect(near(f.speed, 160.7, 0.1) && near(f.climb, -3.25, 0.01))
        #expect(f.time == t0 - 1.2)
        #expect(ac[1].altBaro?.feet == nil && ac[1].fix(receivedAt: t0) == nil)  // on the ground
        #expect(ac[2].fix(receivedAt: t0) == nil)  // no position
        #expect(ac[3].fix(receivedAt: t0) == nil)  // stale
        #expect(try Aircraft.decode(Data(#"{"msg":"No error","now":1}"#.utf8)).isEmpty)
    }

    @Test func decodesRoutesAndUnknownCallsigns() {
        let json = """
        {"response":{"flightroute":{"callsign":"BAW117","callsign_icao":"BAW117","callsign_iata":"BA117",
          "airline":{"name":"British Airways","icao":"BAW","iata":"BA","country":"United Kingdom","country_iso":"GB","callsign":"SPEEDBIRD"},
          "origin":{"country_iso_name":"GB","country_name":"United Kingdom","elevation":83,"iata_code":"LHR","icao_code":"EGLL",
                    "latitude":51.4706,"longitude":-0.461941,"municipality":"London","name":"London Heathrow Airport"},
          "destination":{"country_iso_name":"US","country_name":"United States","elevation":13,"iata_code":"JFK","icao_code":"KJFK",
                    "latitude":40.639801,"longitude":-73.7789,"municipality":"New York","name":"John F Kennedy International Airport"}}}}
        """
        let r = Route.decode(Data(json.utf8))
        #expect(r?.airline?.name == "British Airways")
        #expect(r?.origin.code == "LHR" && r?.destination.municipality == "New York")
        #expect(r?.destination.latitude == 40.639801)
        #expect(Route.decode(Data(#"{"response":"unknown callsign"}"#.utf8)) == nil)
        #expect(Route.decode(Data("<html>".utf8)) == nil)
    }

    @Test func recordsAndReplaysInALoop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overhead-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var rec = try Recorder(directory: dir, observer: home)
        for i in 1...3 { try rec.append(Data("{\"ac\":[],\"i\":\(i)}".utf8)) }
        var replay = try Replay(directory: dir)
        #expect(replay.observer == home)
        let seen = (0..<4).map { _ in replay.next() }
        #expect(seen.map { $0.wrapped } == [false, false, false, true])
        #expect(seen[3].data == seen[0].data)
    }

    /// The whole pipeline on the synthetic flyover: decode, fix, trigger, present.
    @Test func syntheticFlyoverDropsCollapsesAndLeaves() throws {
        var replay = Replay.flyover(over: home)
        var p = Presenter()
        var drops: [Int] = [], compactAt: Int?, hiddenAt: Int?, badged: Set<Int> = []
        for k in 0..<replay.frames.count {
            let now = t0 + Double(k) * 10
            let candidates = try Aircraft.decode(replay.next().data).compactMap { a -> Candidate? in
                guard let f = a.fix(receivedAt: now) else { return nil }
                return Candidate(hex: a.hex, look: look(from: home, to: f.position(at: now)), triggered: Pass.triggers(f, from: home, at: now))
            }
            if p.update(candidates, at: now) { drops.append(k) }
            if p.phase == .compact, compactAt == nil { compactAt = k }
            if p.phase == .hidden, !drops.isEmpty, hiddenAt == nil { hiddenAt = k }
            if p.others > 0 { badged.insert(k) }
        }
        #expect(drops == [3])
        #expect(compactAt == 9)
        #expect(hiddenAt == 20)
        #expect(badged == Set(3...12))
        #expect(replay.routes["OVH101"]?.origin.code == "SOU")
    }
}
