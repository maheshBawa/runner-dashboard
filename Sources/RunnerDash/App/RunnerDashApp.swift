// Runner Dashboard: menu bar + window dashboard for self-hosted GitHub Actions runners in ~/actions-runner*.
// Build: scripts/build.sh   Self-check: ~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest
import AppKit
import SwiftUI

enum Route: Hashable {
    case runner(String), network
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationStack(path: $store.path) {
            OverviewView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .runner(let dir): RunnerDetailView(dir: dir)
                    case .network: NetworkView()
                    }
                }
        }
        .alert("Action failed", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.error ?? "")
        }
        .onAppear {
            store.automation.openRunner = { [weak store] dir in
                store?.path = [.runner(dir)]
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct RunnerDashApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Runner Dashboard", id: "dashboard") {
            RootView().environmentObject(store).environmentObject(store.net).environmentObject(store.automation).frame(minWidth: 860, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 900)

        MenuBarExtra {
            MenuPanel().environmentObject(store).environmentObject(store.net).environmentObject(store.automation)
        } label: {
            MenuBarLabel(icon: store.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            selfTest()
        } else if CommandLine.arguments.contains("--preview-icon") {
            requestMenuIconPreview()
        } else if CommandLine.arguments.contains("--notify-test") {
            let sent = DispatchSemaphore(value: 0)
            postTestNotification { ok in print(ok ? "sent" : "notifications are off for Runner Dashboard (System Settings › Notifications)"); sent.signal() }
            sent.wait()
        } else {
            RunnerDashApp.main()
        }
    }
}
