import SwiftUI

/// Shown in the menu panel and the window when a newer Runner Dashboard release is out, and while it installs.
struct AppUpdateBanner: View {
    @EnvironmentObject var automation: Automation
    var body: some View {
        if let latest = automation.latestAppVersion, automation.appUpdateAvailable {
            VStack(alignment: .leading, spacing: 8) {
                if let step = automation.appUpdateStep {
                    ProgressView(value: step.fraction) {
                        Text("\(step.rawValue) v\(latest)…").font(.callout.weight(.medium))
                    }
                    .tint(.infoFill)
                    .animation(.easeInOut, value: step)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.infoMark)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Update available").font(.callout.weight(.semibold))
                            Text("v\(latest) · you have v\(appVersion ?? "?")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update now") { automation.installAppUpdate() }.buttonStyle(.borderedProminent).tint(.infoFill)
                    }
                    if let error = automation.appUpdateError {
                        Text(error).font(.caption).foregroundStyle(Color.dangerText).lineLimit(3)
                    }
                }
            }
            .card(padding: 12)
        }
    }
}
