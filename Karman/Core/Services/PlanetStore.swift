import Foundation
import Observation

/// Owns the live planet snapshot: cached start, periodic refresh, offline fallback.
@MainActor
@Observable
final class PlanetStore {
    private(set) var snapshot: PlanetSnapshot = .empty
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var isOffline = false
    private(set) var usingDirectFeeds = false
    private(set) var auroraGrid: [UInt8]?
    private(set) var version = 0

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let api = APIClient.shared

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "snapshot.json")
    }

    init() {
        loadCache()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (snap, tag, raw) = try await api.snapshot(etag: snapshot.quakes.isEmpty ? nil : etag)
            etag = tag
            apply(snap)
            isOffline = false
            usingDirectFeeds = false
            try? raw.write(to: Self.cacheURL, options: .atomic)
        } catch APIClient.APIError.notModified {
            lastUpdated = Date()
            isOffline = false
        } catch {
            // The Kármán API is unreachable: go straight to the public feeds.
            if let direct = try? await DirectFeeds.snapshot() {
                apply(direct)
                usingDirectFeeds = true
                isOffline = false
            } else {
                isOffline = snapshot.quakes.isEmpty
            }
        }
    }

    private func apply(_ snap: PlanetSnapshot) {
        snapshot = snap
        auroraGrid = snap.aurora?.decoded()
        lastUpdated = Date()
        version &+= 1
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let snap = try? KarmanJSON.decoder().decode(PlanetSnapshot.self, from: data) else { return }
        snapshot = snap
        auroraGrid = snap.aurora?.decoded()
        lastUpdated = snap.generatedAt
        version &+= 1
    }

    // MARK: Lookups

    func quake(id: String) -> Quake? { snapshot.quakes.first { $0.id == id } }
    func event(id: String) -> NaturalEvent? { snapshot.events.first { $0.id == id } }
    func launch(id: String) -> Launch? { snapshot.launches.first { $0.id == id } }

    var quakesLast24h: [Quake] {
        let cutoff = Date().addingTimeInterval(-86400)
        return snapshot.quakes.filter { $0.time > cutoff }
    }

    var strongestRecentQuake: Quake? {
        let cutoff = Date().addingTimeInterval(-86400 * 2)
        return snapshot.quakes.filter { $0.time > cutoff }.max { $0.mag < $1.mag }
    }

    var activeStorms: [NaturalEvent] {
        snapshot.events.filter { $0.kind == .storm }.sorted { ($0.value ?? 0) > ($1.value ?? 0) }
    }

    var wildfires: [NaturalEvent] { snapshot.events.filter { $0.kind == .wildfire } }

    var upcomingLaunches: [Launch] {
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        return snapshot.launches.filter { $0.net > cutoff }.sorted { $0.net < $1.net }
    }

    func auroraChance(at point: GeoPoint?) -> Int? {
        guard let point, let grid = auroraGrid else { return nil }
        return AuroraMath.visibleChance(grid: grid, width: 360, at: point)
    }
}
