import Foundation

// Mirrors the Kármán API "planet snapshot" schema (backend/internal/planet/model.go).

nonisolated struct PlanetSnapshot: Codable, Sendable, Equatable {
    var generatedAt: Date
    var quakes: [Quake]
    var events: [NaturalEvent]
    var aurora: AuroraGrid?
    var space: SpaceWeather?
    var launches: [Launch]
    var neos: [NearEarthObject]
    var sources: [SourceState]?

    static let empty = PlanetSnapshot(generatedAt: .distantPast, quakes: [], events: [], aurora: nil, space: nil, launches: [], neos: [], sources: nil)
}

nonisolated struct Quake: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var mag: Double
    var place: String
    var time: Date
    var lat: Double
    var lon: Double
    var depthKm: Double
    var tsunami: Bool?
    var felt: Int?
    var alert: String?
    var sig: Int
    var url: String?

    var coordinate: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    var isTsunamiFlagged: Bool { tsunami ?? false }

    /// Seismic energy in joules (Gutenberg–Richter energy relation).
    var energyJoules: Double { pow(10, 1.5 * mag + 4.8) }
    /// TNT equivalent in tonnes (1 t TNT = 4.184e9 J).
    var tntTonnes: Double { energyJoules / 4.184e9 }
}

nonisolated struct TrackPoint: Codable, Sendable, Hashable {
    var lat: Double
    var lon: Double
    var time: Date
    var value: Double?
}

nonisolated enum EventKind: String, Codable, Sendable, CaseIterable {
    case wildfire, storm, volcano, ice, flood, dust, drought, landslide, snow, heat, other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EventKind(rawValue: raw) ?? .other
    }
}

nonisolated struct NaturalEvent: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var kind: EventKind
    var title: String
    var lat: Double
    var lon: Double
    var time: Date
    var value: Double?
    var unit: String?
    var track: [TrackPoint]?
    var source: String?
    var sourceUrl: String?

    var coordinate: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

nonisolated struct AuroraGrid: Codable, Sendable, Equatable {
    var observed: Date
    var forecast: Date
    var maxNorth: Int
    var maxSouth: Int
    var grid: String
    var gridWidth: Int
    var gridHeight: Int

    /// Decoded probabilities (0–100), row-major from latitude -90 to 90, longitude 0..359 E.
    func decoded() -> [UInt8]? {
        guard let data = Data(base64Encoded: grid), data.count == gridWidth * gridHeight else { return nil }
        return [UInt8](data)
    }
}

nonisolated struct Sample: Codable, Sendable, Hashable {
    var t: Date
    var v: Double
}

nonisolated struct Flare: Codable, Sendable, Hashable {
    var begin: Date
    var peak: Date
    var end: Date?
    var `class`: String
}

nonisolated struct SpaceAlert: Codable, Sendable, Hashable, Identifiable {
    var time: Date
    var code: String
    var title: String
    var message: String
    var id: String { code + time.description }
}

nonisolated struct SpaceWeather: Codable, Sendable, Equatable {
    var kp: Double
    var kpEstimated: Double
    var kpTime: Date?
    var gScale: Int
    var kpHistory: [Sample]?
    var kpForecast: [Sample]?
    var windSpeed: Double
    var windDensity: Double
    var bz: Double
    var bt: Double
    var windTime: Date?
    var windHistory: [Sample]?
    var bzHistory: [Sample]?
    var xrayFlux: Double
    var xrayClass: String
    var xrayTime: Date?
    var xrayHistory: [Sample]?
    var flares: [Flare]?
    var alerts: [SpaceAlert]?

    /// The best "now" Kp: the 1-minute estimate when it is newer than the 3-hour value.
    var kpNow: Double { max(kp, kpEstimated) }
}

nonisolated struct Launch: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var provider: String
    var rocket: String
    var mission: String?
    var orbit: String?
    var pad: String
    var location: String
    var lat: Double
    var lon: Double
    var net: Date
    var status: String
    var statusAbbrev: String
    var webcast: String?
    var image: String?

    var coordinate: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    var missionName: String {
        let parts = name.components(separatedBy: " | ")
        return parts.count > 1 ? parts[1] : name
    }
    var isDone: Bool { ["Success", "Failure", "Partial Failure"].contains(statusAbbrev) }
}

nonisolated struct NearEarthObject: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var approach: Date
    var missKm: Double
    var missLunar: Double
    var diameterMinM: Double
    var diameterMaxM: Double
    var velocityKps: Double
    var hazardous: Bool
    var url: String?
}

nonisolated struct SourceState: Codable, Sendable, Hashable {
    var name: String
    var updatedAt: Date?
    var ok: Bool
}

/// Compact OMM element set (CelesTrak) for on-device SGP4.
nonisolated struct OrbitalElements: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var id: Int
    var epoch: String
    var mm: Double
    var ecc: Double
    var inc: Double
    var raan: Double
    var argp: Double
    var ma: Double
    var bstar: Double
    var ndot: Double
    var nddot: Double
}

// MARK: - Briefing

nonisolated struct Briefing: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var language: String
    var title: String
    var dek: String
    var scenes: [BriefingScene]
    var signoff: String
    var generatedAt: Date
    var source: String
}

nonisolated struct BriefingScene: Codable, Sendable, Hashable {
    var focus: String
    var refId: String
    var lat: Double
    var lon: Double
    var altitudeKm: Double
    var headline: String
    var narration: String
}

// MARK: - Decoding

nonisolated enum KarmanJSON {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseISO8601(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func parseISO8601(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return d }
        // Go may emit nanosecond precision; trim to milliseconds.
        if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot {
            let frac = s[s.index(after: dot)..<z].prefix(3)
            let trimmed = String(s[..<dot]) + "." + frac + String(s[z...])
            return try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return nil
    }
}
