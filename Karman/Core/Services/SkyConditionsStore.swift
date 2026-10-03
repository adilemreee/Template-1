import Foundation
import Observation

/// Hourly cloud cover for stargazing (MET Norway via the Kármán API). The location leaves the
/// phone rounded to half a degree (about 50 km), and the forecast is reused for 30 minutes.
@MainActor
@Observable
final class SkyConditionsStore {
    private(set) var clouds: [Stargazing.CloudSample] = []
    private(set) var isLoading = false
    private(set) var failed = false
    @ObservationIgnored private var fetchedFor: GeoPoint?
    @ObservationIgnored private var fetchedAt: Date?

    func refresh(for observer: GeoPoint) async {
        let rounded = GeoPoint(lat: (observer.lat * 2).rounded() / 2, lon: (observer.lon * 2).rounded() / 2)
        if let at = fetchedAt, fetchedFor == rounded, Date().timeIntervalSince(at) < 1800 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fc = try await APIClient.shared.clouds(lat: rounded.lat, lon: rounded.lon)
            clouds = fc.points.map { Stargazing.CloudSample(date: $0.t, cloud: $0.cloud, humidity: $0.humidity) }
            fetchedFor = rounded
            fetchedAt = Date()
            failed = false
        } catch {
            failed = clouds.isEmpty
        }
    }
}
