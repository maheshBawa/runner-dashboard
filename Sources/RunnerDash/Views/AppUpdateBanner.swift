import SwiftUI

/// Shown in the menu panel and the window when a scheduled check finds a newer release.
struct AppUpdateBanner: View {
    @EnvironmentObject var updater: AppUpdater
    var body: some View {
        if let latest = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.infoMark)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.callout.weight(.semibold))
                    Text("v\(latest) · you have v\(appVersion ?? "?")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update now") { updater.checkForUpdates() }.buttonStyle(.borderedProminent).tint(.infoFill)
            }
            .card(padding: 12)
        }
    }
}
