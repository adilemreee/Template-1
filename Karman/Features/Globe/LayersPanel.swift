import SwiftUI

struct LayersPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    private struct Item: Identifiable {
        var id: String { icon }
        var title: LocalizedStringKey
        var icon: String
        var tint: Color
        var keyPath: WritableKeyPath<GlobeLayers, Bool>
    }

    private let items: [Item] = [
        Item(title: "Earthquakes", icon: "waveform.path.ecg", tint: Theme.quake, keyPath: \.quakes),
        Item(title: "Storms", icon: "hurricane", tint: Theme.storm, keyPath: \.storms),
        Item(title: "Wildfires", icon: "flame.fill", tint: Theme.fire, keyPath: \.fires),
        Item(title: "Volcanoes & more", icon: "mountain.2.fill", tint: Theme.volcano, keyPath: \.otherEvents),
        Item(title: "Aurora", icon: "light.beacon.max.fill", tint: Theme.aurora, keyPath: \.aurora),
        Item(title: "Space Station", icon: "dot.circle.and.hand.point.up.left.fill", tint: Theme.ice, keyPath: \.satellites),
        Item(title: "Starlink swarm", icon: "circle.grid.3x3.fill", tint: Color(red: 0.55, green: 0.7, blue: 1), keyPath: \.starlink),
        Item(title: "Launches", icon: "airplane.departure", tint: Theme.launch, keyPath: \.launches),
        Item(title: "Clouds", icon: "cloud.fill", tint: .white, keyPath: \.clouds),
        Item(title: "City lights", icon: "building.2.fill", tint: Color(red: 1, green: 0.78, blue: 0.45), keyPath: \.cityLights),
    ]

    var body: some View {
        // Small phones scroll; everything else shows the whole panel.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LAYERS").eyebrow()
                Spacer()
                Text("\(model.settings.layers.activeCount) on")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            LiveImageryToggle()
            WeatherLayersSection(isPresented: $isPresented)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items) { item in
                    let on = model.settings.layers[keyPath: item.keyPath]
                    Button {
                        Haptics.shared.select()
                        var l = model.settings.layers
                        l[keyPath: item.keyPath].toggle()
                        withAnimation(.snappy) { model.applyLayers(l) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(on ? item.tint : Theme.textTertiary)
                                .frame(width: 20)
                                .symbolEffect(.bounce, value: on)
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? .white : Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(on ? item.tint.opacity(0.16) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(on ? item.tint.opacity(0.45) : Theme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}

/// Wind, temperature and rain from NOAA's GFS model, plus the planet's extremes right now.
private struct WeatherLayersSection: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    static let rainTint = Color(red: 0.36, green: 0.80, blue: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("LIVE WEATHER").eyebrow(Theme.ice)
                Spacer()
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 8) {
                tile("Wind", subtitle: "10 m flow", icon: "wind", tint: Theme.ice, keyPath: \.wind)
                tile("Temperature", subtitle: "2 m air", icon: "thermometer.medium", tint: Theme.quakeWarm, keyPath: \.temperature)
                tile("Rain & snow", subtitle: "radar-style", icon: "cloud.rain.fill", tint: Self.rainTint, keyPath: \.rain)
            }
            if !model.weather.extremes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.weather.extremes) { x in extremeButton(x) }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private var status: String {
        if model.weather.isLoading && !model.weather.hasData { return String(localized: "loading…") }
        guard let run = model.weather.modelTime else { return "NOAA GFS" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return String(localized: "NOAA GFS · \(String(format: "%02d", cal.component(.hour, from: run)))Z")
    }

    private func tile(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String, tint: Color, keyPath: WritableKeyPath<GlobeLayers, Bool>) -> some View {
        let on = model.settings.layers[keyPath: keyPath]
        return Button {
            Haptics.shared.select()
            var l = model.settings.layers
            l[keyPath: keyPath].toggle()
            withAnimation(.snappy) { model.applyLayers(l) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? tint : Theme.textTertiary)
                    .symbolEffect(.bounce, value: on)
                    .frame(height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? .white : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? tint.opacity(0.16) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? tint.opacity(0.45) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(on ? "On" : "Off"))
    }

    private func extremeButton(_ x: WeatherExtreme) -> some View {
        let units = model.settings.units
        let (icon, tint, label, value): (String, Color, String, String) = switch x.kind {
        case .hottest: ("thermometer.sun.fill", Theme.quakeWarm, String(localized: "Hottest"), Fmt.temperature(x.value, units: units))
        case .coldest: ("snowflake", Theme.ice, String(localized: "Coldest"), Fmt.temperature(x.value, units: units))
        case .windiest: ("wind", Color.white, String(localized: "Windiest"), Fmt.windSpeed(x.value, units: units))
        case .wettest: ("cloud.heavyrain.fill", Self.rainTint, String(localized: "Wettest"), Fmt.rainRate(x.value, units: units))
        }
        return Button {
            Haptics.shared.tap()
            var l = model.settings.layers
            switch x.kind {
            case .hottest, .coldest: l.temperature = true
            case .windiest: l.wind = true
            case .wettest: l.rain = true
            }
            model.applyLayers(l)
            isPresented = false
            model.select(.spot(x.point))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(label) place on Earth right now: \(value). Show it."))
    }
}

private struct LiveImageryToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.settings.layers.liveImagery
        Button {
            Haptics.shared.select()
            var l = model.settings.layers
            l.liveImagery.toggle()
            withAnimation(.snappy) { model.applyLayers(l) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.3, blue: 0.6), Color(red: 0.05, green: 0.12, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Real Earth from yesterday")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("NASA VIIRS satellite mosaic · actual clouds & storms")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                if LiveImagery.shared.isLoading && on {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(on ? Theme.ice : Theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Theme.ice.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Theme.ice.opacity(0.4) : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

extension GlobeLayers {
    var activeCount: Int {
        [quakes, storms, fires, otherEvents, aurora, satellites, starlink, launches, clouds, cityLights, liveImagery,
         wind, temperature, rain, plates].filter { $0 }.count
    }
}
