import CoreLocation
import MapKit
import SwiftUI

/// Names a tapped point ("Near Kyoto, Japan", "the Pacific Ocean") and finds its time zone.
@MainActor
enum SpotNamer {
    struct Info: Sendable, Equatable {
        var name: String
        var timeZone: TimeZone?
    }

    private static var cache: [String: Info] = [:]

    static func info(for p: GeoPoint) async -> Info {
        let key = String(format: "%.1f,%.1f", p.lat, p.lon)
        if let hit = cache[key] { return hit }
        var info = Info(name: RideAlongOverlay.ocean(at: p).capitalizedFirst, timeZone: nil)
        if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: p.lat, longitude: p.lon)) {
            request.preferredLocale = Locale(identifier: "en_US") // place names in English, like the rest of the app
            if let item = try? await request.mapItems.first {
                let reps = item.addressRepresentations
                let parts = [reps?.cityName, reps?.regionName].compactMap { $0 }.filter { !$0.isEmpty }
                if let name = parts.isEmpty ? item.name : parts.joined(separator: ", ") { info.name = name }
                info.timeZone = item.timeZone
            }
        }
        cache[key] = info
        return info
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Inspector content for any point on Earth: live weather from the GFS frames, the next day's
/// outlook, local time and daylight, and how far it is from you.
struct SpotSummary: View {
    @Environment(AppModel.self) private var model
    let point: GeoPoint
    @State private var info: SpotNamer.Info?

    var body: some View {
        let units = model.settings.units
        let now = Date()
        let sample = model.weather.sample(at: point, date: now)
        let sunAlt = Astro.sunAltitude(at: now, observer: point)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                EventGlyph(icon: Self.symbol(sample, sunAltitude: sunAlt), tint: Self.tint(sample), size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    if let watched = model.settings.place(near: point) {
                        Text("\(watched.name.uppercased()) · \((info?.name ?? "").uppercased())")
                            .eyebrow(Theme.place)
                            .lineLimit(1)
                    } else {
                        Text((info?.name ?? String(localized: "This spot")).uppercased())
                            .eyebrow(Theme.ice)
                            .lineLimit(1)
                    }
                    if let s = sample {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Fmt.temperature(s.tempC, units: units))
                                .font(.display(30, weight: .bold))
                                .foregroundStyle(.white)
                            Text(Fmt.rainWord(s.rainMMH, tempC: s.tempC) + " · " + Fmt.windWord(s.windSpeed))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(s.windFrom + 180))
                                .foregroundStyle(Theme.ice)
                            Text("\(Fmt.windSpeed(s.windSpeed, units: units)) from \(GeoPoint.compassName(s.windFrom))")
                            if s.rainMMH >= 0.1 {
                                Text("·")
                                Text(Fmt.rainRate(s.rainMMH, units: units))
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(model.weather.failed ? "Live weather is unavailable right now" : "Loading live weather…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(daylightLine(now: now, sunAltitude: sunAlt))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            if sample != nil {
                SpotOutlook(point: point)
            }
            HStack(spacing: 8) {
                PillButton(title: "Ask about this", icon: "sparkle", tint: Theme.aurora) {
                    model.ask(about: askContext(sample: sample, now: now, sunAltitude: sunAlt))
                }
                if model.weather.hasData && !model.settings.layers.anyWeather {
                    PillButton(title: "Show wind", icon: "wind", tint: Theme.ice) {
                        var l = model.settings.layers
                        l.wind = true
                        model.applyLayers(l)
                    }
                }
            }
        }
        .task(id: point) {
            model.weather.refreshIfNeeded()
            info = nil
            info = await SpotNamer.info(for: point)
        }
    }

    private func daylightLine(now: Date, sunAltitude: Double) -> String {
        var parts: [String] = []
        if let tz = info?.timeZone {
            parts.append(String(localized: "Local \(now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz)))"))
        } else {
            // Mean solar time when the time zone is unknown (open ocean).
            let solar = now.addingTimeInterval(point.lon / 15 * 3600)
            parts.append(String(localized: "Solar time \(solar.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: "UTC")!)))"))
        }
        if sunAltitude > 0 {
            parts.append(String(localized: "Sun \(Int(sunAltitude.rounded()))° up"))
        } else if sunAltitude > -6 {
            parts.append(String(localized: "Twilight"))
        } else {
            parts.append(String(localized: "Night"))
        }
        if let user = model.location.point {
            parts.append(Fmt.distance(point.distanceKm(to: user), units: model.settings.units) + " " + String(localized: "away"))
        }
        return parts.joined(separator: " · ")
    }

    private func askContext(sample: WeatherGrid.Sample?, now: Date, sunAltitude: Double) -> APIClient.AskAbout {
        var details = [Fmt.coordinate(point)]
        if let s = sample {
            details.append(String(format: "GFS now: %.0f °C, wind %.0f km/h from %@, precipitation %.1f mm/h", s.tempC, s.windSpeed * 3.6, GeoPoint.compassName(s.windFrom), s.rainMMH))
        }
        details.append(String(format: "Sun altitude %.0f°", sunAltitude))
        return APIClient.AskAbout(refId: "spot", kind: "spot", title: info?.name ?? Fmt.coordinate(point), details: details.joined(separator: "; "))
    }

    static func symbol(_ s: WeatherGrid.Sample?, sunAltitude: Double) -> String {
        guard let s else { return "mappin.and.ellipse" }
        if s.rainMMH >= 0.3 { return s.tempC < 0.5 ? "cloud.snow.fill" : (s.rainMMH > 8 ? "cloud.heavyrain.fill" : "cloud.rain.fill") }
        if s.windSpeed > 13 { return "wind" }
        if s.tempC > 35 { return "thermometer.sun.fill" }
        if s.tempC < -15 { return "snowflake" }
        return sunAltitude > 0 ? "sun.max.fill" : "moon.stars.fill"
    }

    static func tint(_ s: WeatherGrid.Sample?) -> Color {
        guard let s else { return Theme.ice }
        if s.rainMMH >= 0.3 { return Color(red: 0.36, green: 0.80, blue: 0.85) }
        if s.windSpeed > 13 { return Theme.ice }
        switch s.tempC {
        case 30...: return Theme.quakeWarm
        case 18..<30: return Theme.sun
        case 5..<18: return Theme.aurora
        default: return Theme.ice
        }
    }
}

/// The next day at a point in five steps: temperature, rain and wind.
private struct SpotOutlook: View {
    @Environment(AppModel.self) private var model
    let point: GeoPoint

    var body: some View {
        let series = model.weather.series(at: point)
        let units = model.settings.units
        HStack(spacing: 0) {
            ForEach(Array(series.enumerated()), id: \.offset) { i, entry in
                VStack(spacing: 3) {
                    Text(i == 0 ? String(localized: "Now") : entry.date.formatted(.dateTime.hour()))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: entry.sample.rainMMH >= 0.3 ? (entry.sample.tempC < 0.5 ? "snowflake" : "drop.fill") : "wind")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.sample.rainMMH >= 0.3 ? Color(red: 0.36, green: 0.80, blue: 0.85) : Theme.textSecondary)
                        .frame(height: 14)
                    Text(Fmt.temperature(entry.sample.tempC, units: units))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(Fmt.windSpeed(entry.sample.windSpeed, units: units).components(separatedBy: " ").first ?? "")
                        .font(.mono(9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}
