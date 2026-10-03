import Foundation
import Observation

/// The last year of M4.5+ earthquakes (about 7,000–9,000 events) for the year replay.
/// Downloaded on demand and kept on disk for 12 hours.
@MainActor
@Observable
final class QuakeHistoryStore {
    private(set) var year: APIClient.QuakeYear?
    private(set) var isLoading = false
    private(set) var failed = false
    @ObservationIgnored private var loadedAt: Date?

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "quakes-year.json")
    }

    struct Tally: Equatable {
        var count = 0
        var m6 = 0
        var m7 = 0
        var strongest: Quake?
    }

    /// The year, fresh enough to replay (cached for 12 hours; stale data beats none when offline).
    func load() async -> APIClient.QuakeYear? {
        if let year, let loadedAt, Date().timeIntervalSince(loadedAt) < 12 * 3600 { return year }
        if year == nil, let (cached, savedAt) = Self.readCache() {
            year = cached
            loadedAt = savedAt
            if Date().timeIntervalSince(savedAt) < 12 * 3600 { return cached }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (fresh, raw) = try await APIClient.shared.quakeYear()
            year = Self.sorted(fresh)
            loadedAt = Date()
            failed = false
            try? raw.write(to: Self.cacheURL, options: .atomic)
        } catch {
            failed = year == nil
        }
        return year
    }

    /// Counts for the whole year.
    var totals: Tally {
        guard let quakes = year?.quakes else { return Tally() }
        return Self.tally(quakes[...])
    }

    static func tally(_ quakes: ArraySlice<Quake>) -> Tally {
        var t = Tally()
        for q in quakes {
            t.count += 1
            if q.mag >= 6 { t.m6 += 1 }
            if q.mag >= 7 { t.m7 += 1 }
            if q.mag > (t.strongest?.mag ?? 0) { t.strongest = q }
        }
        return t
    }

    private static func sorted(_ y: APIClient.QuakeYear) -> APIClient.QuakeYear {
        var y = y
        y.quakes.sort { $0.time < $1.time }
        return y
    }

    private static func readCache() -> (APIClient.QuakeYear, Date)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let y = try? KarmanJSON.decoder().decode(APIClient.QuakeYear.self, from: data),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path()),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return (sorted(y), date)
    }
}
