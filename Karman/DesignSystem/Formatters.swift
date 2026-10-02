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
}
