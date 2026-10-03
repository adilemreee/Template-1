import ActivityKit
import SwiftUI
import WidgetKit

struct LaunchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LaunchActivityAttributes.self) { context in
            LaunchLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.rocket).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    } icon: {
                        Image(systemName: "airplane.departure").foregroundStyle(WTheme.launchTint)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...max(Date(), context.state.net), countsDown: true)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(WTheme.launchTint)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.mission).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text("\(context.attributes.provider) · \(context.attributes.location)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "airplane.departure").foregroundStyle(WTheme.launchTint)
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.net), countsDown: true)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WTheme.launchTint)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "airplane.departure").foregroundStyle(WTheme.launchTint)
            }
            .keylineTint(WTheme.launchTint)
        }
    }
}

private struct LaunchLockScreenView: View {
    let context: ActivityViewContext<LaunchActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(WTheme.launchTint.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: "airplane.departure").font(.system(size: 18, weight: .semibold)).foregroundStyle(WTheme.launchTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("LIFTOFF").font(.system(size: 10, weight: .bold).width(.expanded)).tracking(1.5).foregroundStyle(WTheme.launchTint)
                Text(context.attributes.mission).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text("\(context.attributes.rocket) · \(context.attributes.location)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(timerInterval: Date()...max(Date(), context.state.net), countsDown: true)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
        .padding(16)
    }
}
