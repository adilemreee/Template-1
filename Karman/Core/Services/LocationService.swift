import CoreLocation
import Foundation
import Observation

/// Approximate location for "near you" features. Stored coarsely and never leaves the device
/// except rounded to ~50 km for alert registration.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var point: GeoPoint?
    private(set) var placeName: String?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var lastGeocoded: CLLocation?

    private static let latKey = "karman.location.lat", lonKey = "karman.location.lon", nameKey = "karman.location.name", manualKey = "karman.location.manual"

    var isManual: Bool { UserDefaults.standard.bool(forKey: Self.manualKey) }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5000
        authorization = manager.authorizationStatus
        let d = UserDefaults.standard
        #if DEBUG
        // Simulator testing: KARMAN_FAKE_LOCATION="41.01,28.98,Istanbul"
        if let fake = ProcessInfo.processInfo.environment["KARMAN_FAKE_LOCATION"] {
            let parts = fake.split(separator: ",").map { String($0) }
            if parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) {
                d.set(true, forKey: Self.manualKey)
                store(GeoPoint(lat: lat, lon: lon), name: parts.count > 2 ? parts[2] : nil)
                return
            }
        }
        #endif
        if d.object(forKey: Self.latKey) != nil {
            point = GeoPoint(lat: d.double(forKey: Self.latKey), lon: d.double(forKey: Self.lonKey))
            placeName = d.string(forKey: Self.nameKey)
        }
    }

    func requestIfNeeded() {
        guard !isManual else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func setManual(_ p: GeoPoint, name: String) {
        UserDefaults.standard.set(true, forKey: Self.manualKey)
        store(p, name: name)
    }

    func useDeviceLocation() {
        UserDefaults.standard.set(false, forKey: Self.manualKey)
        requestIfNeeded()
    }

    private func store(_ p: GeoPoint, name: String?) {
        point = p
        if let name { placeName = name }
        let d = UserDefaults.standard
        d.set(p.lat, forKey: Self.latKey)
        d.set(p.lon, forKey: Self.lonKey)
        if let name { d.set(name, forKey: Self.nameKey) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways, !self.isManual { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            guard !self.isManual else { return }
            let p = GeoPoint(lat: (loc.coordinate.latitude * 100).rounded() / 100, lon: (loc.coordinate.longitude * 100).rounded() / 100)
            self.store(p, name: nil)
            await self.reverseGeocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func reverseGeocode(_ loc: CLLocation) async {
        if let last = lastGeocoded, last.distance(from: loc) < 20_000, placeName != nil { return }
        lastGeocoded = loc
        if let mark = try? await geocoder.reverseGeocodeLocation(loc).first {
            let name = mark.locality ?? mark.administrativeArea ?? mark.country
            if let name, let p = point { store(p, name: name) }
        }
    }
}
