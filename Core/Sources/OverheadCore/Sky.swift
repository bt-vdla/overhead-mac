import Foundation

// MARK: - Geometry

/// Where the user stands. Altitude is metres above the WGS84 ellipsoid, the same datum as ADS-B `alt_geom`.
public struct Observer: Sendable, Codable, Equatable, Hashable {
    public var lat: Double, lon: Double, alt: Double
    public init(lat: Double, lon: Double, alt: Double = 0) { self.lat = lat; self.lon = lon; self.alt = alt }
}

/// An aircraft's position at one instant. Altitude is metres; track is degrees true, clockwise from north.
public struct Position: Sendable, Equatable {
    public var lat: Double, lon: Double, alt: Double, track: Double
    public init(lat: Double, lon: Double, alt: Double, track: Double = 0) {
        self.lat = lat; self.lon = lon; self.alt = alt; self.track = track
    }
}

/// How an aircraft looks from the observer.
public struct Look: Sendable, Equatable {
    /// Degrees clockwise from true north, 0..<360.
    public var azimuth: Double
    /// Degrees above the horizon.
    public var elevation: Double
    /// Straight-line metres.
    public var range: Double

    public var compass: String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((azimuth / 45).rounded()) % 8]
    }
}

private let a = 6_378_137.0, f = 1 / 298.257223563, e2 = f * (2 - f)
private let earthRadius = 6_371_008.8
private func rad(_ d: Double) -> Double { d * .pi / 180 }
private func deg(_ r: Double) -> Double { r * 180 / .pi }

private func ecef(_ lat: Double, _ lon: Double, _ h: Double) -> (Double, Double, Double) {
    let φ = rad(lat), λ = rad(lon)
    let n = a / (1 - e2 * sin(φ) * sin(φ)).squareRoot()
    return ((n + h) * cos(φ) * cos(λ), (n + h) * cos(φ) * sin(λ), (n * (1 - e2) + h) * sin(φ))
}

/// Azimuth, elevation and slant range on the WGS84 ellipsoid (ECEF difference rotated into local east-north-up).
public func look(from o: Observer, to p: Position) -> Look {
    let (x0, y0, z0) = ecef(o.lat, o.lon, o.alt), (x1, y1, z1) = ecef(p.lat, p.lon, p.alt)
    let dx = x1 - x0, dy = y1 - y0, dz = z1 - z0
    let φ = rad(o.lat), λ = rad(o.lon)
    let e = -sin(λ) * dx + cos(λ) * dy
    let n = -sin(φ) * cos(λ) * dx - sin(φ) * sin(λ) * dy + cos(φ) * dz
    let u = cos(φ) * cos(λ) * dx + cos(φ) * sin(λ) * dy + sin(φ) * dz
    let az = deg(atan2(e, n))
    return Look(azimuth: az < 0 ? az + 360 : az, elevation: deg(atan2(u, (e * e + n * n).squareRoot())),
                range: (dx * dx + dy * dy + dz * dz).squareRoot())
}

/// The point `distance` metres from (lat, lon) along `bearing`, on a sphere. Over a few km the sphere-versus-ellipsoid error is centimetres.
public func destination(lat: Double, lon: Double, bearing: Double, distance: Double) -> (lat: Double, lon: Double) {
    let φ1 = rad(lat), λ1 = rad(lon), θ = rad(bearing), δ = distance / earthRadius
    let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
    let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
    return (deg(φ2), deg(λ2))
}

// MARK: - Motion

/// One ADS-B fix in SI units, stamped with when it was true.
public struct Fix: Sendable, Equatable {
    public var lat: Double, lon: Double, alt: Double
    /// Ground speed m/s, track degrees, vertical rate m/s.
    public var speed: Double, track: Double, climb: Double
    public var time: Date

    public init(lat: Double, lon: Double, alt: Double, speed: Double = 0, track: Double = 0, climb: Double = 0, time: Date) {
        self.lat = lat; self.lon = lon; self.alt = alt; self.speed = speed; self.track = track; self.climb = climb; self.time = time
    }

    /// Longest a fix is extrapolated. A stale fix stops where it was instead of flying off on a guess.
    public static let maxCoast: TimeInterval = 60

    /// Dead-reckoned along a great circle at constant speed, track and climb.
    public func position(at t: Date) -> Position {
        let dt = min(max(t.timeIntervalSince(time), 0), Self.maxCoast)
        let p = destination(lat: lat, lon: lon, bearing: track, distance: speed * dt)
        return Position(lat: p.lat, lon: p.lon, alt: alt + climb * dt, track: track)
    }
}

/// What gets drawn for one aircraft: its dead-reckoned path, plus an offset that fades over 1.5 s after each new
/// fix, so a correction glides into place instead of jumping.
public struct Motion: Sendable {
    public private(set) var fix: Fix
    private var offset = Position(lat: 0, lon: 0, alt: 0, track: 0)
    private var since = Date.distantPast

    public static let blend: TimeInterval = 1.5

    public init(_ fix: Fix) { self.fix = fix }

    public func position(at t: Date) -> Position {
        var p = fix.position(at: t)
        let s = min(max(t.timeIntervalSince(since) / Self.blend, 0), 1)
        let k = 1 - s * s * (3 - 2 * s)  // smoothstep: leaves and lands without a kick
        guard k > 0 else { return p }
        p.lat += offset.lat * k; p.lon += offset.lon * k; p.alt += offset.alt * k
        p.track = (p.track + offset.track * k).truncatingRemainder(dividingBy: 360)
        if p.track < 0 { p.track += 360 }
        return p
    }

    /// Takes a new fix at `now`. Whatever was on screen at `now` stays there; the gap closes over `blend`.
    public mutating func update(_ new: Fix, at now: Date) {
        let shown = position(at: now), target = new.position(at: now)
        // ponytail: plain lon difference, wrong for one frame at the antimeridian; normalise if anyone flies the Pacific dateline overhead.
        var turn = (shown.track - target.track).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
        offset = Position(lat: shown.lat - target.lat, lon: shown.lon - target.lon, alt: shown.alt - target.alt, track: turn)
        fix = new
        since = now
    }
}

// MARK: - Overhead

public enum Pass {
    public static let minElevation = 25.0
    public static let maxRange = 25_000.0
    /// How far ahead a pass is predicted, seconds.
    public static let lookahead: TimeInterval = 20
    /// Once shown, an aircraft stays until it sinks below this.
    public static let keepElevation = 15.0

    public static func qualifies(_ l: Look) -> Bool { l.elevation >= minElevation && l.range <= maxRange }

    /// Overhead now, or at any whole second in the next `lookahead` along the dead-reckoned path.
    public static func triggers(_ fix: Fix, from o: Observer, at now: Date) -> Bool {
        stride(from: 0, through: lookahead, by: 1).contains { qualifies(look(from: o, to: fix.position(at: now + $0))) }
    }
}

/// One aircraft as the presenter sees it this poll.
public struct Candidate: Sendable {
    public var hex: String
    public var look: Look
    public var triggered: Bool
    public init(hex: String, look: Look, triggered: Bool) { self.hex = hex; self.look = look; self.triggered = triggered }
}

/// The panel's phase machine. It drops on a new pass, stays open for `openFor`, then shrinks to a compact pill
/// until the shown aircraft sinks below `Pass.keepElevation`.
public struct Presenter: Sendable {
    public enum Phase: Sendable, Equatable { case hidden, expanded, compact }

    public private(set) var phase = Phase.hidden
    public private(set) var hex: String?
    /// Other aircraft also overhead, for the badge.
    public private(set) var others = 0
    public private(set) var openedAt: Date?

    public static let openFor: TimeInterval = 60

    public init() {}

    /// Returns true when the panel drops, the moment to play the sound.
    @discardableResult
    public mutating func update(_ candidates: [Candidate], at now: Date) -> Bool {
        let active = candidates.filter { $0.triggered || ($0.hex == hex && $0.look.elevation >= Pass.keepElevation) }
        guard let best = active.max(by: { $0.look.elevation < $1.look.elevation }) else {
            self = Presenter()
            return false
        }
        hex = best.hex
        others = active.count - 1
        if phase == .hidden {
            phase = .expanded
            openedAt = now
            return true
        }
        tick(at: now)
        return false
    }

    /// Moves expanded to compact once `openFor` has passed. Call it from a timer too, so collapsing doesn't wait for the next poll.
    public mutating func tick(at now: Date) {
        if phase == .expanded, let openedAt, now.timeIntervalSince(openedAt) >= Self.openFor { phase = .compact }
    }
}
