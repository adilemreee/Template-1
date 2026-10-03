import SwiftUI

/// First-launch card shown after the opening cinematic: asks for location and alerts in
/// context instead of interrupting the intro with system prompts.
struct OnboardingCard: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if step == 0 {
                Label { Text("MAKE IT YOURS").eyebrow(Theme.ice) } icon: { Image(systemName: "location.fill").foregroundStyle(Theme.ice) }
                Text("See the planet from where you stand")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Kármán can show earthquakes near you, your chance of seeing the aurora tonight and when the space station flies over. Your exact location never leaves your iPhone.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Haptics.shared.tap()
                        model.location.useDeviceLocation()
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = 1 }
                    } label: {
                        Text("Use my location").frame(maxWidth: .infinity)
                    }
                    .primaryAction()
                    Button {
                        model.panel = .settings
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = 1 }
                    } label: {
                        Text("Choose a place").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            } else {
                Label { Text("ALERTS").eyebrow(Theme.aurora) } icon: { Image(systemName: "bell.badge.fill").foregroundStyle(Theme.aurora) }
                Text("Never miss the sky")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Get a heads-up for strong earthquakes nearby, aurora you can actually see and space station passes overhead. Fine-tune everything in Settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Haptics.shared.tap()
                        Task {
                            _ = await NotificationService.shared.requestAuthorization()
                            await NotificationService.shared.syncRegistration()
                            await model.recomputePasses(force: true)
                            finish()
                        }
                    } label: {
                        Text("Turn on alerts").frame(maxWidth: .infinity)
                    }
                    .primaryAction(Theme.aurora)
                    Button { finish() } label: {
                        Text("Not now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if step == 0 {
                Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = 1 } } label: {
                    Text("Skip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        }
    }

    private func finish() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { model.onboardingDone = true }
    }
}
