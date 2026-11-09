import Foundation

// MARK: - adsb.lol

/// One aircraft from adsb.lol's `/v2/point/{lat}/{lon}/{nm}` (readsb JSON). Every field but `hex` can be missing.
public struct Aircraft: Decodable, Sendable, Equatable {
    public var hex: String
    public var flight: String?
    /// Registration, ICAO type code, type description.
    public var r: String?, t: String?, desc: String?
    public var lat: Double?, lon: Double?
    /// Feet, or "ground".
    public var altBaro: Altitude?
    public var altGeom: Double?
    /// Knots, degrees, feet per minute.
    public var gs: Double?, track: Double?, baroRate: Double?, geomRate: Double?
    /// Seconds since the position was received.
    public var seenPos: Double?

    public struct Altitude: Decodable, Sendable, Equatable {
        /// Nil on the ground.
        public var feet: Double?
        public init(feet: Double?) { self.feet = feet }
        public init(from decoder: any Decoder) throws { feet = try? decoder.singleValueContainer().decode(Double.self) }
    }

    public var callsign: String? {
        let c = flight?.trimmingCharacters(in: .whitespaces) ?? ""
        return c.isEmpty ? nil : c
    }

    /// Positions older than this are dropped.
    public static let maxAge: TimeInterval = 60

    /// The fix in SI units, or nil when there's no usable airborne position.
    public func fix(receivedAt now: Date) -> Fix? {
        if let b = altBaro, b.feet == nil { return nil }  // on the ground
        guard let lat, let lon, let feet = altGeom ?? altBaro?.feet, (seenPos ?? 0) <= Self.maxAge else { return nil }
        return Fix(lat: lat, lon: lon, alt: feet * 0.3048, speed: (gs ?? 0) * 0.514444, track: track ?? 0,
                   climb: (baroRate ?? geomRate ?? 0) * 0.00508, time: now.addingTimeInterval(-(seenPos ?? 0)))
    }

    public static func decode(_ data: Data) throws -> [Aircraft] {
        struct Point: Decodable { var ac: [Aircraft]? }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Point.self, from: data).ac ?? []
    }
}

// MARK: - adsbdb

/// A flight route from adsbdb's `/v0/callsign/{callsign}`.
public struct Route: Codable, Sendable, Equatable {
    public struct Airline: Codable, Sendable, Equatable { public var name: String?, iata: String?, icao: String? }
    public struct Airport: Codable, Sendable, Equatable {
        public var iataCode: String?, icaoCode: String?, name: String?, municipality: String?
        public var latitude: Double, longitude: Double
        public var code: String { iataCode ?? icaoCode ?? "—" }
        public init(iataCode: String?, icaoCode: String? = nil, name: String? = nil, municipality: String?, latitude: Double, longitude: Double) {
            self.iataCode = iataCode; self.icaoCode = icaoCode; self.name = name; self.municipality = municipality
            self.latitude = latitude; self.longitude = longitude
        }
    }
    public var airline: Airline?
    public var origin: Airport, destination: Airport

    public init(airline: Airline?, origin: Airport, destination: Airport) {
        self.airline = airline; self.origin = origin; self.destination = destination
    }

    /// The route, or nil for "unknown callsign" (adsbdb answers that with a string in place of the object).
    public static func decode(_ data: Data) -> Route? {
        struct Envelope: Decodable {
            struct Body: Decodable { var flightroute: Route? }
            enum K: CodingKey { case response }
            var route: Route?
            init(from d: any Decoder) throws { route = try? d.container(keyedBy: K.self).decode(Body.self, forKey: .response).flightroute }
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return (try? d.decode(Envelope.self, from: data))?.route
    }
}

// MARK: - Replay

/// Writes each live response to a folder, with the observer in `meta.json`, so it can be replayed later.
public struct Recorder: Sendable {
    public let directory: URL
    private var count = 0

    public init(directory: URL, observer: Observer) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(observer).write(to: directory.appendingPathComponent("meta.json"))
    }

    public mutating func append(_ data: Data) throws {
        count += 1
        try data.write(to: directory.appendingPathComponent(String(format: "%05d.json", count)))
    }
}

/// Plays recorded responses in a loop from a spoofed observer.
public struct Replay: Sendable {
    public let observer: Observer
    public let frames: [Data]
    /// Routes the replay knows already, so the synthetic flight draws its arc offline.
    public let routes: [String: Route]
    private var index = 0

    public init(observer: Observer, frames: [Data], routes: [String: Route] = [:]) {
        precondition(!frames.isEmpty, "A replay needs at least one frame")
        self.observer = observer; self.frames = frames; self.routes = routes
    }

    public init(directory: URL) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") && $0 != "meta.json" }.sorted()
        guard !names.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let observer = try JSONDecoder().decode(Observer.self, from: Data(contentsOf: directory.appendingPathComponent("meta.json")))
        self.init(observer: observer, frames: try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) })
    }

    /// The next frame. `wrapped` is true when the loop starts over, so the caller can forget every track instead of
    /// letting aircraft glide backwards.
    public mutating func next() -> (data: Data, wrapped: Bool) {
        defer { index += 1 }
        return (frames[index % frames.count], index > 0 && index % frames.count == 0)
    }

    /// No network needed: one aircraft straight over `o` from the south at 3 km, and a second 6 km east so the badge
    /// shows. Frames are 10 s apart, the same as live polling.
    public static func flyover(over o: Observer, every: TimeInterval = 10) -> Replay {
        func plane(_ hex: String, _ callsign: String, east: Double, height: Double, speed: Double, k: Int) -> [String: Any] {
            let abeam = destination(lat: o.lat, lon: o.lon, bearing: 90, distance: east)
            let start = destination(lat: abeam.lat, lon: abeam.lon, bearing: 180, distance: 12_000)
            let p = destination(lat: start.lat, lon: start.lon, bearing: 0, distance: speed * every * Double(k))
            return ["hex": hex, "flight": callsign.padding(toLength: 8, withPad: " ", startingAt: 0), "t": "A320",
                    "desc": "AIRBUS A-320", "r": "G-OVHD", "lat": p.lat, "lon": p.lon,
                    "alt_baro": Int((o.alt + height) / 0.3048), "alt_geom": Int((o.alt + height) / 0.3048),
                    "gs": speed / 0.514444, "track": 0, "baro_rate": 0, "seen_pos": 0.5]
        }
        let frames = (0..<24).map { k in
            let ac = [plane("4ca7b1", "OVH101", east: 0, height: 3_000, speed: 120, k: k),
                      plane("406b2e", "OVH202", east: 6_000, height: 4_000, speed: 140, k: k)]
            return try! JSONSerialization.data(withJSONObject: ["ac": ac, "msg": "No error"] as [String: Any])
        }
        let south = destination(lat: o.lat, lon: o.lon, bearing: 180, distance: 400_000)
        let north = destination(lat: o.lat, lon: o.lon, bearing: 0, distance: 600_000)
        let route = Route(airline: .init(name: "Overhead Air", iata: "OV", icao: "OVH"),
                          origin: .init(iataCode: "SOU", municipality: "Southfield", latitude: south.lat, longitude: south.lon),
                          destination: .init(iataCode: "NTH", municipality: "Northgate", latitude: north.lat, longitude: north.lon))
        return Replay(observer: o, frames: frames, routes: ["OVH101": route, "OVH202": route])
    }
}
