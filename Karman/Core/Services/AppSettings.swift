import Foundation
import Observation

enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial
}

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var layers: GlobeLayers { didSet { save(layers, "layers") } }
    var playIntro: Bool { didSet { defaults.set(playIntro, forKey: "playIntro") } }
    var showUserLocation: Bool { didSet { defaults.set(showUserLocation, forKey: "showUserLocation") } }
    var units: UnitSystem { didSet { defaults.set(units.rawValue, forKey: "units") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var soundscape: Bool { didSet { defaults.set(soundscape, forKey: "soundscape") } }
    var narration: Bool { didSet { defaults.set(narration, forKey: "narration") } }
    var alerts: AlertPreferences { didSet { save(alerts, "alerts") } }

    struct AlertPreferences: Codable, Equatable, Sendable {
        var quakesNearby = true
        var quakeMinMag = 4.5
        var quakeRadiusKm = 500.0
        var majorQuakes = true
        var aurora = true
        var auroraMinChance = 20
        var launches = false
        var spaceStorms = true
        var issPasses = true
    }

    init() {
        layers = Self.load("layers", from: defaults) ?? GlobeLayers()
        playIntro = defaults.object(forKey: "playIntro") as? Bool ?? true
        showUserLocation = defaults.object(forKey: "showUserLocation") as? Bool ?? true
        units = UnitSystem(rawValue: defaults.string(forKey: "units") ?? "") ?? (Locale.current.measurementSystem == .us ? .imperial : .metric)
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        soundscape = defaults.object(forKey: "soundscape") as? Bool ?? true
        narration = defaults.object(forKey: "narration") as? Bool ?? true
        alerts = Self.load("alerts", from: defaults) ?? AlertPreferences()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum SatelliteCache {
    struct Entry {
        var elements: [OrbitalElements]
        var savedAt: Date
        var isStale: Bool { Date().timeIntervalSince(savedAt) > 10 * 3600 }
    }

    private static func url(_ group: SatelliteEngine.Group) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "sats-\(group.rawValue).json")
    }

    static func save(group: SatelliteEngine.Group, raw: Data) {
        try? raw.write(to: url(group), options: .atomic)
    }

    static func load(group: SatelliteEngine.Group) -> Entry? {
        let u = url(group)
        guard let data = try? Data(contentsOf: u),
              let els = try? JSONDecoder().decode([OrbitalElements].self, from: data),
              let attrs = try? FileManager.default.attributesOfItem(atPath: u.path()),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Entry(elements: els, savedAt: date)
    }
}
