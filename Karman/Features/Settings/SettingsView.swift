import MapKit
import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @State private var showCities = false
    @State private var showPlacePicker = false
    @State private var pendingPlace: (point: GeoPoint, name: String)?
    @State private var placeName = ""
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
                    Text("Alerts use your location rounded to about 50 km. Space Station reminders are computed on this device. Kármán is not an emergency warning service: always follow your local authorities.")
                }
                .onChange(of: settings.alerts) {
                    Task {
                        await NotificationService.shared.syncRegistration()
                        await model.recomputePasses(force: true)
                    }
                }

                Section {
                    ForEach(settings.places) { place in
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.place)
                            Text(place.name)
                            Spacer()
                            if let me = model.location.point {
                                Text(Fmt.distance(place.point.distanceKm(to: me), units: settings.units))
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        settings.places.remove(atOffsets: offsets)
                        placesChanged()
                    }
                    if settings.places.count < WatchedPlace.limit {
                        Button { showPlacePicker = true } label: { Label("Add a place…", systemImage: "plus.circle.fill") }
                    }
                } header: {
                    Text("Watched places")
                } footer: {
                    Text("Family, a second home, somewhere you're travelling: earthquake alerts also cover these places, with the magnitude and distance set above. They appear on the globe and leave your phone rounded to about 50 km.")
                }

                Section {
                    Button {
                        dismiss()
                        model.startAmbient()
                    } label: {
                        Label("Ambient globe", systemImage: "moon.zzz.fill")
                    }
                } header: {
                    Text("Nightstand")
                } footer: {
                    Text("A slowly turning, dimmed globe with a clock and the planet's latest news. Great on a stand while charging.")
                }

                Section {
                    Toggle("Share questions with Claude", isOn: $settings.askConsent)
                } header: {
                    Text("Ask Kármán")
                } footer: {
                    Text("Your questions and a location rounded to about 50 km are sent to Kármán's server and to Anthropic to generate answers. Turn this off to stop sharing; Ask Kármán will ask again before your next question.")
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
            .sheet(isPresented: $showCities) {
                CityPicker(title: "Choose a place") { point, name in
                    model.location.setManual(point, name: name)
                    model.syncScene(force: true)
                    model.refreshDerived()
                }
            }
            .sheet(isPresented: $showPlacePicker) {
                CityPicker(title: "Watch a place") { point, name in
                    placeName = name
                    // Ask for a friendly name once the picker has gone.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        pendingPlace = (point, name)
                    }
                }
            }
            .alert("Name this place", isPresented: Binding(get: { pendingPlace != nil }, set: { if !$0 { pendingPlace = nil } })) {
                TextField("Name", text: $placeName)
                Button("Save") {
                    if let p = pendingPlace {
                        let name = placeName.trimmingCharacters(in: .whitespaces)
                        model.settings.places.append(WatchedPlace(name: name.isEmpty ? p.name : name, lat: p.point.lat, lon: p.point.lon))
                        placesChanged()
                    }
                    pendingPlace = nil
                }
                Button("Cancel", role: .cancel) { pendingPlace = nil }
            } message: {
                Text("For example “Mum and Dad” or “Lisbon flat”.")
            }
            .task { await NotificationService.shared.refreshStatus(); notificationsAuthorized = NotificationService.shared.authorized }
        }
    }
}

private struct CityPicker: View {
    @Environment(\.dismiss) private var dismiss
    var title: LocalizedStringKey
    var onPick: (GeoPoint, String) -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    let c = item.location.coordinate
                    onPick(GeoPoint(lat: c.latitude, lon: c.longitude), item.name ?? "")
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

extension SettingsView {
    private func placesChanged() {
        model.syncScene(force: true)
        Task { await NotificationService.shared.syncRegistration() }
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
        ("NOAA GFS via PacIOOS ERDDAP", "Live wind, temperature and precipitation"),
        ("MET Norway", "Cloud forecast for stargazing (CC BY 4.0)"),
        ("USGS FDSN Event Service", "A year of earthquakes for the year replay"),
        ("P. Bird (2003), PB2002", "Tectonic plate boundaries (ODC-By 1.0, via H. Ahlenius / Nordpil)"),
        ("JPL Solar System Dynamics", "Approximate planetary orbital elements (E. M. Standish)"),
        ("IASP91 Earth model", "Seismic wave travel times"),
        ("International Meteor Organization", "Meteor shower calendar"),
        ("d3-celestial, Olaf Frohn", "Constellation figures and star names (BSD-3-Clause)"),
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
                Text("• No accounts, no ads, no analytics or tracking SDKs.\n• Your precise location never leaves your device. Alerts, answers and the stargazing cloud forecast use it rounded to about 50 km; watched places are rounded the same way.\n• Questions you ask are sent to our server and to Anthropic's Claude only after you agree, to generate an answer; they are not used to build a profile or to train AI models.\n• The Sky Lens uses the camera only to show the live view on your screen; nothing is recorded or sent.\n• Notification tokens are stored only to deliver the alerts you chose, and are deleted when you turn alerts off.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.85)).lineSpacing(4)
            }
            .padding(20)
        }
        .background(PanelBackground())
        .navigationTitle("Privacy")
    }
}
