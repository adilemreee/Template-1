import MapKit
import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @State private var showCities = false
    @State private var notificationsAuthorized = NotificationService.shared.authorized

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AIOrb(small: true).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kármán").font(.display(20, weight: .bold))
                            Text("The living planet · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Location") {
                    LabeledContent("Current") {
                        Text(model.location.placeName ?? model.location.point.map(Fmt.coordinate) ?? String(localized: "Not set"))
                    }
                    Button { model.location.useDeviceLocation() } label: { Label("Use my location", systemImage: "location.fill") }
                    Button { showCities = true } label: { Label("Choose a place…", systemImage: "magnifyingglass") }
                    Toggle("Show me on the globe", isOn: $settings.showUserLocation)
                        .onChange(of: settings.showUserLocation) { model.syncScene(force: true) }
                }

                Section("Experience") {
                    Toggle("Opening cinematic", isOn: $settings.playIntro)
                    Toggle("Narrated briefings", isOn: $settings.narration)
                    Toggle("Ambient soundscape", isOn: $settings.soundscape)
                    Toggle("Haptics", isOn: $settings.haptics)
                        .onChange(of: settings.haptics) { _, v in Haptics.shared.enabled = v }
                    Picker("Units", selection: $settings.units) {
                        Text("Metric").tag(UnitSystem.metric)
                        Text("Imperial").tag(UnitSystem.imperial)
                    }
                }

                Section {
                    if !notificationsAuthorized {
                        Button {
                            Task { notificationsAuthorized = await NotificationService.shared.requestAuthorization() }
                        } label: {
                            Label("Turn on alerts", systemImage: "bell.badge.fill")
                        }
                    }
                    Toggle("Earthquakes near me", isOn: $settings.alerts.quakesNearby)
                    if settings.alerts.quakesNearby {
                        VStack(alignment: .leading) {
                            Text("Magnitude \(Fmt.magnitude(settings.alerts.quakeMinMag)) or stronger").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            Slider(value: $settings.alerts.quakeMinMag, in: 3...7, step: 0.5)
                            Text("Within \(Fmt.distance(settings.alerts.quakeRadiusKm, units: settings.units))").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            Slider(value: $settings.alerts.quakeRadiusKm, in: 100...2000, step: 50)
                        }
                    }
                    Toggle("Major earthquakes worldwide (M7+)", isOn: $settings.alerts.majorQuakes)
                    Toggle("Aurora visible from here", isOn: $settings.alerts.aurora)
                    Toggle("Geomagnetic storms (G3+)", isOn: $settings.alerts.spaceStorms)
                    Toggle("Space Station passes", isOn: $settings.alerts.issPasses)
                    Toggle("Rocket launches", isOn: $settings.alerts.launches)
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Alerts use your location rounded to about 50 km. Space Station reminders are computed on this device.")
                }
                .onChange(of: settings.alerts) {
                    Task {
                        await NotificationService.shared.syncRegistration()
                        await model.recomputePasses(force: true)
                    }
                }

                Section("About") {
                    NavigationLink { CreditsView() } label: { Label("Data sources & credits", systemImage: "books.vertical") }
                    NavigationLink { PrivacyView() } label: { Label("Privacy", systemImage: "hand.raised") }
                    Button { requestReview() } label: { Label("Rate Kármán", systemImage: "star") }
                    ShareLink(item: URL(string: "https://apps.apple.com/app/id0000000000")!, message: Text("The living planet, live. Kármán")) {
                        Label("Share Kármán", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Text("One purchase. Every feature, forever. No ads, no tracking, no subscriptions.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PanelBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCities) { CityPicker() }
            .task { await NotificationService.shared.refreshStatus(); notificationsAuthorized = NotificationService.shared.authorized }
        }
    }
}

private struct CityPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    let c = item.location.coordinate
                    model.location.setManual(GeoPoint(lat: c.latitude, lon: c.longitude), name: item.name ?? "")
                    model.syncScene(force: true)
                    model.refreshDerived()
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "").foregroundStyle(.white)
                        Text(Fmt.coordinate(GeoPoint(lat: item.location.coordinate.latitude, lon: item.location.coordinate.longitude)))
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or place")
            .task(id: query) {
                guard query.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                // Geocode the place name worldwide first, then add points of interest.
                var found: [MKMapItem] = []
                if let geo = MKGeocodingRequest(addressString: query) {
                    geo.region = MKCoordinateRegion(.world)
                    found += (try? await geo.mapItems) ?? []
                }
                let req = MKLocalSearch.Request()
                req.naturalLanguageQuery = query
                req.region = MKCoordinateRegion(.world)
                req.resultTypes = [.address, .pointOfInterest]
                found += (try? await MKLocalSearch(request: req).start().mapItems) ?? []
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                results = found.filter { item in
                    let key = "\(Int(item.location.coordinate.latitude * 10)),\(Int(item.location.coordinate.longitude * 10))"
                    return seen.insert(key).inserted
                }
            }
            .navigationTitle("Choose a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct CreditsView: View {
    private let credits: [(String, String)] = [
        ("USGS Earthquake Hazards Program", "Real-time earthquake feeds"),
        ("NOAA Space Weather Prediction Center", "Kp index, solar wind, X-rays, alerts, OVATION aurora model"),
        ("NOAA GOES-19 SUVI", "Live images of the Sun"),
        ("NASA EONET", "Storms, wildfires, volcanoes and other natural events"),
        ("NASA GIBS / EOSDIS", "Daily VIIRS true-colour mosaic of the Earth"),
        ("NASA Visible Earth", "Blue Marble Next Generation & Black Marble night lights"),
        ("GEBCO / NASA", "Global relief used for terrain shading"),
        ("NASA SVS CGI Moon Kit", "Lunar surface colour map"),
        ("Yale Bright Star Catalogue", "The real night sky behind the globe"),
        ("CelesTrak", "Satellite orbital elements"),
        ("The Space Devs", "Launch Library 2 schedule"),
        ("NASA JPL / CNEOS · NeoWs", "Asteroid close approaches"),
        ("Anthropic Claude", "Planet Briefing narration and Ask Kármán"),
    ]

    var body: some View {
        List(credits, id: \.0) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text(c.0).font(.system(size: 15, weight: .semibold))
                Text(c.1).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanelBackground())
        .navigationTitle("Data sources")
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Kármán is built to know the planet, not you.").font(.system(size: 20, weight: .bold))
                Text("• No accounts, no ads, no analytics or tracking SDKs.\n• Your precise location never leaves your device. Alerts and answers use it rounded to about 50 km.\n• Questions you ask are sent to our server and to Anthropic's Claude to generate an answer; they are not used to build a profile.\n• Notification tokens are stored only to deliver the alerts you chose, and are deleted when you turn alerts off.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.85)).lineSpacing(4)
            }
            .padding(20)
        }
        .background(PanelBackground())
        .navigationTitle("Privacy")
    }
}
