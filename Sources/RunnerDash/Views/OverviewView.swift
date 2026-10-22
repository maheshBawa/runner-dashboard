import AppKit
import SwiftUI

struct RunnerCard: View {
    @EnvironmentObject var store: Store
    let runner: Runner
    @State private var hover = false

    var body: some View {
        let r = runner
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RunnerIcon(state: r.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.org).font(.headline).lineLimit(1)
                    Text(statusText).font(.caption).foregroundStyle(r.state == .busy ? Color.infoText : .secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusPill(state: r.state)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            RunnerActions(runner: r).controlSize(.small)
        }
        .card()
        .contentShape(Rectangle())
        .onTapGesture { store.path.append(.runner(r.dir)) }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(r.state.tone.mark.opacity(hover ? 0.6 : 0), lineWidth: 1.5))
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }

    private var statusText: String {
        switch runner.state {
        case .busy: return "Running \(runner.current?.name ?? "a job")" + (runner.current?.start.map { " · " + duration(Date().timeIntervalSince($0)) } ?? "")
        case .idle: return "Ready for jobs"
        case .stopped: return "Not running"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var automation: Automation
    @Environment(\.openSettings) private var openSettings
    @State private var confirmDerived = false

    var body: some View {
        let s = store.sys
        let up = store.runners.filter { $0.state != .stopped }.count
        let anyBusy = store.busyCount > 0
        let recent = store.runners.flatMap(\.jobs).sorted { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Runners").font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("\(up) of \(store.runners.count) online · \(store.busyCount) busy").foregroundStyle(.secondary)
                        if automation.keepingAwake {
                            Label { Text("Keeping this Mac awake while a job runs").foregroundStyle(.secondary) } icon: { Image(systemName: "cup.and.saucer.fill").foregroundStyle(Color.infoMark) }.font(.callout)
                        }
                        if !automation.pausedForBattery.isEmpty {
                            Label { Text("Runners paused on low battery; they start again when you plug in").foregroundStyle(.secondary) } icon: { Image(systemName: "battery.25percent").foregroundStyle(Color.warnMark) }.font(.callout)
                        }
                    }
                    Spacer()
                    Button { store.addingRunner = true } label: { Label("Add Runner", systemImage: "plus") }
                        .help("Set up a new runner for an organization or repository")
                    Button {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Notifications, keep awake, automatic cleanup, battery")
                }

                AppUpdateBanner()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(store.runners) { RunnerCard(runner: $0) }
                }
                if store.runners.isEmpty {
                    VStack(spacing: 10) {
                        Text("No runners on this Mac yet").font(.headline)
                        Button { store.addingRunner = true } label: { Label("Add Runner", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .card()
                }

                SectionHeader(title: "Network").padding(.top, 10)
                NetworkSummaryCard()

                SectionHeader(title: "This Mac").padding(.top, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    GaugeTile(title: "CPU", value: "\(ProcessInfo.processInfo.activeProcessorCount) cores", detail: "load " + s.load.map { String(format: "%.1f", $0) }.joined(separator: " · "), fraction: s.cpu / 100, color: .infoMark)
                    GaugeTile(title: "Memory", value: "\(memSize(s.memUsed)) of \(memSize(s.memTotal))", detail: "swap \(memSize(s.swapUsed))", fraction: s.memUsed / s.memTotal, color: .purpleMark)
                    GaugeTile(title: "Disk", value: "\(fileSize(Int64(s.diskFree))) free", detail: "of \(fileSize(Int64(s.diskTotal)))", fraction: s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : 0, color: .tealMark)
                    InfoTile(icon: s.power.contains("AC") ? "bolt.fill" : "battery.75percent", tone: .warn, title: "Power",
                             value: s.battery.map { "\($0)%" } ?? "—", detail: s.power)
                    InfoTile(icon: "thermometer.medium", tone: s.thermal == .nominal ? .ok : .warn, title: "Thermal",
                             value: thermalName(s.thermal), detail: "up " + duration(s.uptime))
                    InfoTile(icon: "shippingbox.fill", tone: .purple, title: "Xcode DerivedData", value: fileSize(store.derivedDataBytes), detail: "build cache, shared") {
                        if store.working.contains(derivedData) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Clear…") { confirmDerived = true }
                                .disabled(anyBusy)
                                .help(anyBusy ? "Not available while a job is running" : "Delete ~/Library/Developer/Xcode/DerivedData contents")
                        }
                    }
                }

                SectionHeader(title: "Recent activity").padding(.top, 10)
                JobList(jobs: Array(recent.prefix(8)), showRunner: true)
            }
            .padding(28)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop(tint: .accentColor))
        .sheet(isPresented: $store.addingRunner) { AddRunnerSheet().environmentObject(store) }
        .confirmationDialog("Clear Xcode DerivedData?", isPresented: $confirmDerived) {
            Button("Delete \(fileSize(store.derivedDataBytes))", role: .destructive) { store.clearDerivedData() }
        } message: {
            Text("Deletes everything in ~/Library/Developer/Xcode/DerivedData. It's shared by all runners and your own Xcode, so the next build of each project will be a full (slower) build.")
        }
    }
}
