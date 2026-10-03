import QuartzCore
import SwiftUI

/// Shown under the status chips while a weather layer is on: plays or scrubs the next day of the
/// GFS forecast on the globe (daylight moves with it) and explains the map colours.
struct WeatherBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let layers = model.settings.layers
        let span = model.forecastSpan
        VStack(alignment: .leading, spacing: 8) {
            if model.weather.hasData && span > 1 {
                HStack(spacing: 10) {
                    Button {
                        model.toggleForecastPlayback()
                    } label: {
                        Image(systemName: model.forecastPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.ice))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(model.forecastPlaying ? "Pause forecast" : "Play the next 24 hours"))

                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !model.forecastPlaying)) { _ in
                        let hours = model.forecastPlaying ? model.globe.forecastHours(at: CACurrentMediaTime()) : model.forecastHours
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hours < 0.5 ? String(localized: "LIVE WEATHER") : String(localized: "FORECAST \(Fmt.forecastOffset(hours: hours))"))
                                    .font(.label(10, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(hours < 0.5 ? Theme.aurora : Theme.ice)
                                Spacer(minLength: 4)
                                Text(Date().addingTimeInterval(hours * 3600).formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.mono(11, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Slider(value: Binding(get: { hours }, set: { model.scrubForecast(to: $0) }), in: 0...span)
                                .tint(Theme.ice)
                                .controlSize(.mini)
                                .accessibilityLabel(Text("Forecast time"))
                                .accessibilityValue(Text(Fmt.forecastOffset(hours: hours)))
                        }
                    }
                }
            } else if model.weather.isLoading || !model.weather.hasData {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(model.weather.warmingUp ? "Fetching NOAA's latest forecast run…"
                         : (model.weather.failed ? "Live weather is unavailable right now. Retrying…" : "Loading live weather…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if layers.temperature && model.weather.hasData {
                TemperatureLegend(units: model.settings.units)
            }
            if layers.rain && model.weather.hasData {
                RainLegend()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The temperature map's colour ramp (matches temperatureRamp in Globe.metal).
struct TemperatureLegend: View {
    var units: UnitSystem

    static let stops: [(Double, Color)] = [
        (-40, Color(red: 0.49, green: 0.29, blue: 0.72)), (-20, Color(red: 0.25, green: 0.46, blue: 0.89)),
        (0, Color(red: 0.26, green: 0.79, blue: 0.91)), (10, Color(red: 0.38, green: 0.80, blue: 0.48)),
        (20, Color(red: 0.96, green: 0.91, blue: 0.38)), (30, Color(red: 0.98, green: 0.65, blue: 0.25)),
        (42, Color(red: 0.89, green: 0.24, blue: 0.37)),
    ]

    var body: some View {
        VStack(spacing: 3) {
            LinearGradient(stops: Self.stops.map { Gradient.Stop(color: $0.1, location: ($0.0 + 40) / 82) }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
            HStack {
                ForEach([-40.0, -20, 0, 20, 40], id: \.self) { c in
                    Text(Fmt.temperature(c, units: units))
                        .font(.mono(9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    if c != 40 { Spacer(minLength: 0) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Temperature colours from violet at minus 40 to red above 40 degrees Celsius"))
    }
}

/// The precipitation map's colour ramp (matches rainRamp in Globe.metal).
struct RainLegend: View {
    var body: some View {
        VStack(spacing: 3) {
            LinearGradient(stops: [
                Gradient.Stop(color: Color(red: 0.26, green: 0.72, blue: 0.78).opacity(0.5), location: 0),
                Gradient.Stop(color: Color(red: 0.36, green: 0.89, blue: 0.55), location: 0.25),
                Gradient.Stop(color: Color(red: 0.98, green: 0.93, blue: 0.36), location: 0.5),
                Gradient.Stop(color: Color(red: 1.0, green: 0.68, blue: 0.27), location: 0.75),
                Gradient.Stop(color: Color(red: 0.95, green: 0.36, blue: 0.84), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(height: 6)
            .clipShape(Capsule())
            HStack {
                Text("drizzle")
                Spacer(minLength: 0)
                Text("rain")
                Spacer(minLength: 0)
                Text("heavy")
                Spacer(minLength: 0)
                Text("extreme")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Precipitation colours from teal drizzle to magenta downpours"))
    }
}
