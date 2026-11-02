// Runner Dashboard: menu bar + window dashboard for self-hosted GitHub Actions runners in ~/actions-runner*.
// Build: scripts/build.sh   Self-check: ~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest
import AppKit
import SwiftUI

enum Route: Hashable {
    case overview, runner(String), network
}

/// Overview, Network and each runner. The selection follows `store.path`, so cards, the menu panel and notifications move it too.
struct Sidebar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List(selection: Binding<Route?>(get: { store.path.last ?? .overview }, set: { store.path = $0.flatMap { $0 == .overview ? nil : [$0] } ?? [] })) {
            Label("Overview", systemImage: "square.grid.2x2").tag(Route.overview)
            Label("Network", systemImage: "network").tag(Route.network)
            Section("Runners") {
                ForEach(store.runners) { r in
                    Label {
                        Text(r.org).lineLimit(1)
                    } icon: {
                        Image(systemName: r.state.icon).foregroundStyle(r.state.tone.mark)
                    }
                    .tag(Route.runner(r.dir))
                    .accessibilityValue(r.state.title)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            // No NavigationStack: a split view pops it to its root whenever the sidebar selection changes.
            switch store.path.last ?? .overview {
            case .overview: OverviewView()
            case .runner(let dir): RunnerDetailView(dir: dir).id(dir)  // a new page per runner, so its logs load too
            case .network: NetworkView()
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
            RootView().environmentObject(store).environmentObject(store.net).environmentObject(store.automation).environmentObject(store.updater).frame(minWidth: 1070, minHeight: 640)
        }
        .defaultSize(width: 1390, height: 900)
        .commands { SidebarCommands() }

        MenuBarExtra {
            MenuPanel().environmentObject(store).environmentObject(store.net).environmentObject(store.automation).environmentObject(store.updater)
        } label: {
            MenuBarLabel(icon: store.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store.updater)
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
