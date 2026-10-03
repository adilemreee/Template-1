import Foundation

enum Fmt {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if abs(s) < 60 { return String(localized: "now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today \(time(date))") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time(date))") }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func utcClock(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func distance(_ km: Double, units: UnitSystem) -> String {
        let m = Measurement(value: units == .metric ? km : km * 0.621371, unit: units == .metric ? UnitLength.kilometers : UnitLength.miles)
        return m.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// Interplanetary distances: "628 million km", "1.2 billion mi".
    static func bigDistance(_ km: Double, units: UnitSystem) -> String {
        let v = units == .metric ? km : km * 0.621371
        let unit = units == .metric ? "km" : "mi"
        if v >= 1e9 { return String(localized: "\((v / 1e9).formatted(.number.precision(.fractionLength(1)))) billion \(unit)") }
        if v >= 1e6 { return String(localized: "\((v / 1e6).formatted(.number.precision(.fractionLength(0)))) million \(unit)") }
        return distance(km, units: units)
    }

    /// How long light takes: "8 min 19 s", "43 min", "4 h 10 min".
    static func lightTime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 600 { return "\(s / 60) min \(s % 60) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// "in 3 months", "2 years ago".
    static func relativeDays(_ days: Double, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: now.addingTimeInterval(days * 86_400), relativeTo: now)
    }

    static func speed(kmPerSecond v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0))) + " km/s"
    }

    static func coordinate(_ p: GeoPoint) -> String {
        let lat = String(format: "%.2f°%@", abs(p.lat), p.lat >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(p.lon), p.lon >= 0 ? "E" : "W")
        return "\(lat)  \(lon)"
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        var s = Int(date.timeIntervalSince(now))
        let sign = s < 0 ? "T+" : "T−"
        s = abs(s)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%@%dd %02d:%02d:%02d", sign, d, h, m, sec) }
        return String(format: "%@%02d:%02d:%02d", sign, h, m, sec)
    }

    static func tnt(_ tonnes: Double) -> String {
        switch tonnes {
        case 1_000_000...: return String(localized: "\((tonnes / 1_000_000).formatted(.number.precision(.fractionLength(1)))) megatons of TNT")
        case 1_000...: return String(localized: "\((tonnes / 1_000).formatted(.number.precision(.fractionLength(1)))) kilotons of TNT")
        default: return String(localized: "\(tonnes.formatted(.number.precision(.fractionLength(0)))) tons of TNT")
        }
    }

    static func magnitude(_ m: Double) -> String { m.formatted(.number.precision(.fractionLength(1))) }

    // MARK: Weather

    static func temperature(_ celsius: Double, units: UnitSystem) -> String {
        let v = units == .metric ? celsius : celsius * 9 / 5 + 32
        return "\(Int(v.rounded()))°"
    }

    static func windSpeed(_ metresPerSecond: Double, units: UnitSystem) -> String {
        units == .metric ? "\(Int((metresPerSecond * 3.6).rounded())) km/h" : "\(Int((metresPerSecond * 2.23694).rounded())) mph"
    }

    static func rainRate(_ mmPerHour: Double, units: UnitSystem) -> String {
        if mmPerHour < 0.1 { return String(localized: "dry") }
        if units == .imperial { return "\((mmPerHour / 25.4).formatted(.number.precision(.fractionLength(2)))) in/h" }
        return "\(mmPerHour.formatted(.number.precision(.fractionLength(mmPerHour < 10 ? 1 : 0)))) mm/h"
    }

    static func rainWord(_ mmPerHour: Double, tempC: Double) -> String {
        let snow = tempC < 0.5
        switch mmPerHour {
        case ..<0.1: return String(localized: "Dry")
        case ..<0.5: return snow ? String(localized: "Light snow") : String(localized: "Drizzle")
        case ..<2.5: return snow ? String(localized: "Snow") : String(localized: "Light rain")
        case ..<8: return snow ? String(localized: "Heavy snow") : String(localized: "Rain")
        case ..<30: return snow ? String(localized: "Blizzard-force snow") : String(localized: "Heavy rain")
        default: return String(localized: "Torrential rain")
        }
    }

    /// Beaufort-style word for a wind speed.
    static func windWord(_ metresPerSecond: Double) -> String {
        switch metresPerSecond {
        case ..<1.5: return String(localized: "Calm")
        case ..<5.5: return String(localized: "Light breeze")
        case ..<10.8: return String(localized: "Breezy")
        case ..<17.2: return String(localized: "Strong wind")
        case ..<24.5: return String(localized: "Gale")
        case ..<32.7: return String(localized: "Storm-force wind")
        default: return String(localized: "Hurricane-force wind")
        }
    }

    /// "+6 h" style offset label for the forecast scrubber.
    static func forecastOffset(hours: Double) -> String {
        hours < 0.5 ? String(localized: "Now") : "+\(Int(hours.rounded())) h"
    }
}
