import Foundation
import Observation

/// Downloads and caches the GFS frames (about 1.3 MB for the next 24 hours, refreshed every
/// 30 minutes at most) and answers "what's the weather here" for any point and time.
@MainActor
@Observable
final class WeatherStore {
    private(set) var grids: [WeatherGrid] = []
    private(set) var version = 0
    private(set) var isLoading = false
    private(set) var failed = false
    /// The server is still fetching NOAA's run (it answers 503 until the first step lands).
    private(set) var warmingUp = false
    /// Hottest, coldest, windiest and wettest places in the current frame.
    private(set) var extremes: [WeatherExtreme] = []

    /// Set once a complete day of frames is in; nil keeps quick retries going.
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var lastAttempt: Date = .distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let api = APIClient.shared

    init() {
        restore()
    }

    var hasData: Bool { !grids.isEmpty }
    var times: [Date] { grids.map(\.valid) }
    var span: ClosedRange<Date>? {
        guard let a = grids.first?.valid, let b = grids.last?.valid else { return nil }
        return a...b
    }
    /// Model time the frames were computed from (the first frame's valid time).
    var modelTime: Date? { grids.first?.valid }

    /// True once the whole next day is in.
    var isComplete: Bool { !grids.isEmpty && fetchedAt != nil }

    /// Fetches the frame list when the last complete check is older than 30 minutes, or every
    /// few seconds while the day is still incomplete.
    func refreshIfNeeded() {
        guard task == nil else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 1800, !grids.isEmpty { return }
        guard Date().timeIntervalSince(lastAttempt) > 8 else { return }
        lastAttempt = Date()
        task = Task { [weak self] in
            await self?.refresh()
            self?.task = nil
        }
    }

    func sample(at p: GeoPoint, date: Date) -> WeatherGrid.Sample? {
        guard let (i, f) = WeatherTimeline.position(of: date, in: times) else { return nil }
        let a = grids[i].sample(at: p)
        guard f > 0, i + 1 < grids.count else { return a }
        return .mix(a, grids[i + 1].sample(at: p), f)
    }

    /// One sample per frame, for the little forecast chart.
    func series(at p: GeoPoint) -> [(date: Date, sample: WeatherGrid.Sample)] {
        grids.map { ($0.valid, $0.sample(at: p)) }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let index = try await api.weatherIndex()
            var next: [WeatherGrid] = []
            var missing = 0
            for f in index.frames {
                if let have = grids.first(where: { $0.id == f.id }) {
                    next.append(have)
                } else if let cached = Self.loadFrame(id: f.id, valid: f.valid) {
                    next.append(cached)
                } else if let data = try? await api.weatherFrame(id: f.id), data.count == WeatherGrid.byteCount {
                    Self.saveFrame(id: f.id, data: data)
                    next.append(WeatherGrid(id: f.id, valid: f.valid, bytes: data))
                } else {
                    missing += 1
                }
            }
            next.sort { $0.valid < $1.valid }
            // The server publishes a cold start's steps one by one: keep polling until the day is in.
            fetchedAt = missing == 0 && index.frames.count >= 5 ? Date() : nil
            failed = next.isEmpty && grids.isEmpty
            warmingUp = false
            if !next.isEmpty, next.map(\.id) != grids.map(\.id) {
                apply(next)
                Self.saveIndex(next)
                Self.prune(keeping: Set(next.map(\.id)))
            }
        } catch APIClient.APIError.http(let code, _) where code == 503 {
            warmingUp = grids.isEmpty
            failed = false
        } catch {
            warmingUp = false
            failed = grids.isEmpty
        }
    }

    private func apply(_ next: [WeatherGrid]) {
        grids = next
        version &+= 1
        let now = Date()
        let current = next.last { $0.valid <= now } ?? next.first
        extremes = current?.extremes() ?? []
    }

    // MARK: Disk cache (frames are immutable per id)

    private struct IndexEntry: Codable { var id: String; var valid: Date }

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "weather", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func frameURL(_ id: String) -> URL {
        directory.appending(path: id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".bin")
    }

    private static func loadFrame(id: String, valid: Date) -> WeatherGrid? {
        guard let data = try? Data(contentsOf: frameURL(id)), data.count == WeatherGrid.byteCount else { return nil }
        return WeatherGrid(id: id, valid: valid, bytes: data)
    }

    private static func saveFrame(id: String, data: Data) {
        try? data.write(to: frameURL(id), options: .atomic)
    }

    private static func saveIndex(_ grids: [WeatherGrid]) {
        let entries = grids.map { IndexEntry(id: $0.id, valid: $0.valid) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: directory.appending(path: "index.json"), options: .atomic)
        }
    }

    private static func prune(keeping ids: Set<String>) {
        let keep = Set(ids.map { frameURL($0).lastPathComponent }).union(["index.json"])
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where !keep.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.directory.appending(path: "index.json")),
              let entries = try? JSONDecoder().decode([IndexEntry].self, from: data) else { return }
        let restored = entries.compactMap { Self.loadFrame(id: $0.id, valid: $0.valid) }
        // Frames older than a day are no use as "now"; wait for fresh ones.
        guard let last = restored.last, Date().timeIntervalSince(last.valid) < 18 * 3600 else { return }
        apply(restored)
    }
}
