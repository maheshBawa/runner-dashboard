import AppKit
import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var net: NetworkUsage
    @EnvironmentObject var automation: Automation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = store.sys
        let up = store.runners.filter { $0.state != .stopped }.count, busy = store.busyCount, total = store.runners.count
        let summary = busy > 0 ? "\(busy) building · \(up) of \(total) online" : up == total ? "All \(total) online · idle" : "\(up) of \(total) online"
        let today = net.total(since: Calendar.current.startOfDay(for: Date()))
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Runners").font(.system(.headline, design: .rounded))
                    HStack(spacing: 5) {
                        Circle().fill(busy > 0 ? Color.infoMark : up < total ? Color.warnMark : Color.okMark).frame(width: 7, height: 7)
                        Text(summary).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer()
                Button(action: addRunner) { Image(systemName: "plus").font(.body.weight(.medium)) }
                    .buttonStyle(.borderless)
                    .help("Add Runner")
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "gearshape").font(.body.weight(.medium)) }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            AppUpdateBanner()

            VStack(spacing: 6) {
                ForEach(store.runners) { r in
                    MenuRunnerRow(runner: r, open: { open([.runner(r.dir)]) }, confirmStop: confirmStop)
                }
                if store.runners.isEmpty {
                    Button(action: addRunner) { Label("Add a Runner", systemImage: "plus").frame(maxWidth: .infinity) }
                        .controlSize(.large)
                }
            }

            if automation.keepingAwake {
                Label { Text("Keeping the Mac awake while a job runs").foregroundStyle(.secondary) } icon: { Image(systemName: "cup.and.saucer.fill").foregroundStyle(Color.infoMark) }
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !automation.pausedForBattery.isEmpty {
                Label { Text("Runners paused on low battery").foregroundStyle(.secondary) } icon: { Image(systemName: "battery.25percent").foregroundStyle(Color.warnMark) }
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                MiniTile(icon: "cpu", color: .infoMark, title: "CPU", value: pct(s.cpu), fraction: s.cpu / 100)
                MiniTile(icon: "memorychip", color: .purpleMark, title: "Memory", value: memSize(s.memUsed), fraction: s.memUsed / s.memTotal)
                MiniTile(icon: "internaldrive", color: .tealMark, title: "Disk free", value: fileSize(Int64(s.diskFree)),
                         fraction: s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : nil)
                MiniTile(icon: connectionIcon(net.current), color: .okMark,
                         title: net.current.map { $0.hasPrefix("Wi-Fi · ") ? String($0.dropFirst(8)) : $0 } ?? "Offline",
                         value: "↓ \(speed(net.rate.rx))", detail: "↑ \(speed(net.rate.tx)) · today \(fileSize(today.total))")
            }

            HStack(spacing: 8) {
                Button { open([]) } label: { Text("Open Dashboard").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Runner Dashboard")
            }
            .controlSize(.large)

            if let appVersion {
                Text("Runner Dashboard v\(appVersion)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.thickMaterial)
    }

    private func confirmStop(_ r: Runner) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop \(r.org)?"
        alert.informativeText = "It goes offline and won't pick up jobs until you press Start."
        alert.addButton(withTitle: "Stop runner").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func addRunner() {
        open([])
        store.addingRunner = true
    }

    private func open(_ path: [Route]) {
        store.path = path
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// "now", "12m", "9h", "3d": short enough for the menu bar panel.
func shortAgo(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = Date().timeIntervalSince(date)
    return s < 60 ? "now" : s < 3600 ? "\(Int(s / 60))m" : s < 86400 ? "\(Int(s / 3600))h" : "\(Int(s / 86400))d"
}

struct MenuRunnerRow: View {
    @EnvironmentObject var store: Store
    let runner: Runner
    let open: () -> Void
    let confirmStop: (Runner) -> Bool
    @State private var hover = false

    var body: some View {
        let r = runner, working = store.working.contains(r.dir)
        HStack(spacing: 10) {
            RunnerIcon(state: r.state, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.org).font(.system(.body, design: .rounded).weight(.semibold)).lineLimit(1)
                switch r.state {
                case .busy:
                    HStack(spacing: 4) {
                        Text("Building \(r.current?.name ?? "a job")").lineLimit(1)
                        Spacer(minLength: 4)
                        if let start = r.current?.start { Text(duration(Date().timeIntervalSince(start))).monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(Color.infoText)
                    ProgressView().progressViewStyle(.linear).controlSize(.small).tint(.infoMark)
                case .idle:
                    HStack(spacing: 4) {
                        Text("Idle").foregroundStyle(Color.okText)
                        if let j = r.jobs.first {
                            Text("·").foregroundStyle(.secondary)
                            Image(systemName: j.result == "Succeeded" ? "checkmark.circle.fill" : j.result.hasPrefix("Cancel") ? "minus.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(j.result == "Succeeded" ? Color.okMark : j.result.hasPrefix("Cancel") ? Color.secondary : Color.dangerMark)
                            Text(j.name).lineLimit(1).truncationMode(.middle)
                            Text(shortAgo(j.end)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                case .stopped:
                    Text("Stopped · not picking up jobs").font(.caption).foregroundStyle(Color.dangerText)
                }
            }
            Spacer(minLength: 4)
            if working {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    let locked = !r.isService || r.isOtherUsers
                    if r.state == .stopped { Button("Start") { store.start(r) }.disabled(locked) }
                    else { Button("Stop…") { if confirmStop(r) { store.stop(r) } }.disabled(r.state == .busy || locked) }
                    Button("Restart") { store.restart(r) }.disabled(r.state == .busy || locked)
                    if r.isOtherUsers { Text("Belongs to \(r.owner)") }
                    else if !r.isService { Text("Started with run.sh: stop or restart it where it runs") }
                    else if r.state == .busy { Text("Busy: stop or restart from the dashboard") }
                    Divider()
                    Button("Open \(r.org)", action: open)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(runner.state.tone.mark.opacity(hover ? 0.6 : 0.12), lineWidth: hover ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help("Open \(r.org)")
    }
}

struct MiniTile: View {
    let icon: String, color: Color, title: String, value: String
    var detail: String? = nil
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.15))
                        Capsule().fill(levelColor(fraction, color)).frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 4)
            } else if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
