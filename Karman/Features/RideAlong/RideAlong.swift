import MapKit
import SwiftUI

/// "Ride with the ISS": a chase camera a little behind and above the station, looking ahead
/// along its track so the curved horizon and the glowing atmosphere frame the shot.
enum RideAlongMath {
    struct Frame {
        var pose: CameraPose
        /// Ground point a little ahead of the station, where sharp imagery should stream.
        var focus: GeoPoint
        var subpoint: GeoPoint
        var altitudeKm: Double
        var speedKmh: Double
    }

    // Camera 0.012 Earth radii (~75 km) above the station and 0.016 rad (~100 km) behind it,
    // tilted 72°: the station sits ~10° below the centre of the view, the horizon just above it.
    private static let tilt = 72.0
    private static let lift = 0.012
    private static let behind = 0.016

    static func frame(for sat: SGP4, at date: Date) -> Frame? {
        guard let now = try? sat.ecef(at: date), let later = try? sat.ecef(at: date.addingTimeInterval(10)),
              let state = try? sat.propagate(to: date) else { return nil }
        let a = SatGeo.subpoint(ecef: now), b = SatGeo.subpoint(ecef: later)
        let heading = a.point.bearing(to: b.point)
        let h = a.altitudeKm / Geo.earthRadiusKm
        let eyeRadius = 1 + h + lift
        let τ = tilt * .pi / 180
        // Solve |t·(1 + A cos τ) − along·A sin τ| = eyeRadius for the pose's slant distance A.
        let slant = -cos(τ) + sqrt(eyeRadius * eyeRadius - sin(τ) * sin(τ))
        let eyeAngle = atan2(slant * sin(τ), 1 + slant * cos(τ))
        let target = a.point.destination(bearing: heading, angle: eyeAngle - behind)
        // Use the track's bearing *at the target*: great circles turn (~1° over 1,000 km here), and the
        // eye sits far behind the target, so the initial bearing would push the station off-centre.
        let headingAtTarget = (target.bearing(to: a.point) + 180).truncatingRemainder(dividingBy: 360)
        let pose = CameraPose(lat: target.lat, lon: target.lon, distance: 1 + slant, tilt: tilt, heading: headingAtTarget)
        let focus = a.point.destination(bearing: heading, angle: 0.06)
        return Frame(pose: pose, focus: focus, subpoint: a.point, altitudeKm: a.altitudeKm,
                     speedKmh: simd_length(state.velocity) * 3600)
    }

    /// Seconds until the station next crosses into or out of Earth's shadow, and which way.
    static func nextTerminator(for sat: SGP4, from date: Date) -> (seconds: TimeInterval, sunrise: Bool)? {
        func lit(_ t: Date) -> Bool? {
            guard let e = try? sat.ecef(at: t) else { return nil }
            return SatGeo.isSunlit(e, sun: Astro.sunECEF(t))
        }
        guard let start = lit(date) else { return nil }
        var lo = 0.0
        var step = 30.0
        var t = step
        while t < 6000 {
            guard let state = lit(date.addingTimeInterval(t)) else { return nil }
            if state != start {
                // Refine the crossing to about a second.
                var hi = t
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if lit(date.addingTimeInterval(mid)) == start { lo = mid } else { hi = mid }
                }
                return (hi, !start)
            }
            lo = t
            t += step
            step = 30
        }
        return nil
    }
}

/// Labels the station, which the chase camera keeps at a fixed spot (centre, 46% below the middle).
struct RideAlongMarker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let engaged = model.globe.isFollowEngaged
            GeometryReader { geo in
                let p = CGPoint(x: geo.size.width / 2, y: geo.size.height * (0.5 + 0.46 * 0.5))
                VStack(spacing: 4) {
                    Text("ISS")
                        .font(.label(10.5, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                    Rectangle().fill(.white.opacity(0.55)).frame(width: 1, height: 26)
                }
                .position(x: p.x, y: p.y - 36)
                .opacity(engaged ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: engaged)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

/// The ride-along HUD: live speed, altitude, what's below and the next orbital sunrise or sunset.
struct RideAlongOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var place: String?
    @State private var lastGeocode = Date.distantPast
    @State private var terminator: (date: Date, sunrise: Bool)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let iss = model.satellites.iss
            let frame = iss.flatMap { RideAlongMath.frame(for: $0, at: ctx.date) }
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        PulsingDot(color: Theme.ice)
                        Text("RIDING WITH THE ISS").eyebrow(Theme.ice)
                        Spacer()
                        Button {
                            Haptics.shared.tap()
                            model.stopRideAlong()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(Text("Leave orbit"))
                    }
                    if let frame {
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            stat(frame.speedKmh.formatted(.number.precision(.fractionLength(0))), "km/h")
                            stat(Int(frame.altitudeKm).formatted(), "km up")
                        }
                        Text(place.map { "Over \($0)" } ?? "Over \(RideAlongOverlay.ocean(at: frame.subpoint))")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                        if let terminator {
                            let left = max(0, terminator.date.timeIntervalSince(ctx.date))
                            Label {
                                Text(terminator.sunrise ? "Orbital sunrise in \(Self.clock(left))" : "Orbital sunset in \(Self.clock(left))")
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: terminator.sunrise ? "sunrise.fill" : "sunset.fill")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(terminator.sunrise ? Theme.sun : Color(red: 1, green: 0.62, blue: 0.4))
                        }
                    }
                }
                .padding(16)
                .glassPanel(cornerRadius: 26)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                Spacer()
                Text("16 sunrises a day · one lap every 92 minutes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassPanel(cornerRadius: 18)
                    .padding(.bottom, 18)
            }
            .task(id: Int(ctx.date.timeIntervalSince1970 / 15)) {
                guard let iss, let frame else { return }
                await refresh(iss: iss, frame: frame, now: ctx.date)
            }
        }
    }

    private func stat(_ value: String, _ unit: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.display(30, weight: .bold)).foregroundStyle(.white).contentTransition(.numericText())
            Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func refresh(iss: SGP4, frame: RideAlongMath.Frame, now: Date) async {
        if let next = RideAlongMath.nextTerminator(for: iss, from: now) {
            terminator = (now.addingTimeInterval(next.seconds), next.sunrise)
        }
        let location = CLLocation(latitude: frame.subpoint.lat, longitude: frame.subpoint.lon)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        request.preferredLocale = Locale(identifier: "en_US") // place names in English, like the rest of the app
        let item = try? await request.mapItems.first
        withAnimation(.easeInOut(duration: 0.6)) {
            place = item?.addressRepresentations?.regionName ?? item?.name
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Rough ocean names for when the reverse geocoder has nothing to say.
    static func ocean(at p: GeoPoint) -> String {
        if p.lat < -60 { return String(localized: "the Southern Ocean") }
        if p.lat > 66 { return String(localized: "the Arctic Ocean") }
        let lon = p.lon
        if lon > 20 && lon < 120 && p.lat < 30 { return String(localized: "the Indian Ocean") }
        if lon > -70 && lon <= 20 { return String(localized: "the Atlantic Ocean") }
        return String(localized: "the Pacific Ocean")
    }
}
