import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            Color.black.ignoresSafeArea()

            GlobeView(controller: model.globe, satellites: model.satellites) {
                model.introFinished()
            }
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel(Text("Live globe"))
            .accessibilityValue(Text("\(model.planet.quakesLast24h.count) earthquakes in the last 24 hours, \(model.planet.activeStorms.count) storms, Kp \((model.planet.snapshot.space?.kpNow ?? 0).formatted(.number.precision(.fractionLength(1))))"))
            .accessibilityHint(Text("Drag to rotate, pinch to zoom, tap a marker for details."))

            IntroTitleView(visible: model.showTitle)
                .allowsHitTesting(false)

            if model.introPlaying {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.skipIntro() }
                    .ignoresSafeArea()
            }

            if model.settings.layers.plates || model.yearReplaying {
                PlateLabels()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if model.hudVisible && !model.briefingActive && !model.ridingISS && !model.replaying && !model.yearReplaying && model.wavesQuake == nil {
                HomeHUD()
                    .transition(.opacity)
            }

            if model.replaying {
                ReplayOverlay()
                    .transition(.opacity)
            }

            if model.yearReplaying {
                YearReplayOverlay()
                    .transition(.opacity)
            }

            if let quake = model.wavesQuake {
                SeismicWavesOverlay(quake: quake)
                    .id(quake.id)
                    .transition(.opacity)
            }

            if model.ridingISS {
                RideAlongMarker()
                RideAlongOverlay()
                    .transition(.opacity)
            }

            SelectionCallout()
                .sheet(item: $model.detailItem) { item in
                    DetailSheet(item: item)
                        .presentationDetents([.large])
                        .presentationCornerRadius(34)
                        .presentationBackground(.clear)
                }

            if model.briefingActive {
                BriefingPlayerView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: Binding(get: { model.shareCard != nil }, set: { if !$0 { model.shareCard = nil } })) {
            if let card = model.shareCard {
                ShareMomentSheet(card: card)
                    .presentationDetents([.large])
                    .presentationCornerRadius(34)
                    .presentationBackground(.clear)
            }
        }
        .sheet(item: $model.panel) { panel in
            PanelHost(panel: panel)
                .presentationBackground(.clear)
        }
        .onAppear {
            NotificationService.shared.model = model
            Haptics.shared.enabled = model.settings.haptics
            model.start()
            if let link = NotificationService.shared.pendingDeepLink {
                NotificationService.shared.route(kind: link.kind, id: link.id, model: model)
                NotificationService.shared.pendingDeepLink = nil
            }
        }
        .onOpenURL { url in
            guard let host = url.host() else { return }
            switch host {
            case "replay":
                model.skipIntro()
                model.startReplay()
            case "year":
                model.skipIntro()
                model.startYearReplay()
            case "ride":
                model.skipIntro()
                model.startRideAlong()
            case "pulse": model.panel = .pulse
            case "space": model.panel = .space
            case "sky": model.panel = .sky
            case "ask": model.panel = .ask
            case "briefing":
                model.skipIntro()
                if !model.briefingActive { BriefingDirector.shared.start(model: model) }
            default: break
            }
        }
        .onChange(of: model.planet.version) {
            model.syncScene()
            model.refreshDerived()
            if model.settings.layers.anyWeather || model.selection.isSpot { model.weather.refreshIfNeeded() }
        }
        .onChange(of: model.weather.version) { model.syncWeather() }
        .onChange(of: model.location.point) {
            model.syncScene()
            model.refreshDerived()
            Task { await NotificationService.shared.syncRegistration() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ReviewPrompter.noteActiveDay()
                model.planet.start()
                model.satellites.start()
                if model.settings.layers.anyWeather { model.weather.refreshIfNeeded() }
                Task { await NotificationService.shared.refreshStatus() }
            case .background:
                model.planet.stop()
                model.satellites.stop()
            default: break
            }
        }
    }
}

/// Sheet container that routes to each panel.
struct PanelHost: View {
    let panel: AppModel.Panel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch panel {
            case .pulse: PulseView()
            case .space: SpaceWeatherView()
            case .sky: SkyTonightView()
            case .ask: AskView()
            case .settings: SettingsView()
            case .briefing: EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if panel != .settings {
                Button {
                    Haptics.shared.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.trailing, 16)
                .accessibilityLabel(Text("Close"))
            }
        }
        .modifier(PanelDetents(panel: panel))
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
    }
}

/// Pulse and Ask open at two heights; Ask drops to half height while the globe flies to an answer.
private struct PanelDetents: ViewModifier {
    @Environment(AppModel.self) private var model
    let panel: AppModel.Panel

    func body(content: Content) -> some View {
        @Bindable var model = model
        switch panel {
        case .ask:
            content
                .presentationDetents([.medium, .large], selection: $model.askDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .pulse:
            content.presentationDetents([.medium, .large])
        default:
            content.presentationDetents([.large])
        }
    }
}
