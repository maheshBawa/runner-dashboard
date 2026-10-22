import SwiftUI

extension View {
    func card(padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return self.padding(padding)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

struct Backdrop: View {
    let tint: Color
    var body: some View {
        LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

struct HelpLabel: View {
    let title: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon) }
            Text(title)
            if explanations[title] != nil { Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
        }
        .help(explanations[title] ?? "")
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.title3.weight(.semibold)).padding(.top, 4) }
}

struct Ring: View {
    let fraction: Double, color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 7)
            Circle().trim(from: 0, to: max(0.002, min(fraction, 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: 58, height: 58)
    }
}

struct IconBadge: View {
    let icon: String, color: Color
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct GaugeTile: View {
    let title: String, value: String, detail: String, fraction: Double, color: Color
    var body: some View {
        HStack(spacing: 14) {
            Ring(fraction: fraction, color: levelColor(fraction, color))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

struct InfoTile<Extra: View>: View {
    let icon: String, tone: Tone, title: String, value: String, detail: String
    @ViewBuilder var extra: Extra
    var body: some View {
        HStack(spacing: 14) {
            ToneBadge(icon: icon, tone: tone, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            extra
        }
        .card()
    }
}

extension InfoTile where Extra == EmptyView {
    init(icon: String, tone: Tone, title: String, value: String, detail: String) {
        self.init(icon: icon, tone: tone, title: title, value: value, detail: detail) { EmptyView() }
    }
}

struct RunnerIcon: View {
    let state: RunnerState
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [state.tone.tileTop, state.tone.fill], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: state.icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: state == .busy)
            )
            .shadow(color: state.tone.fill.opacity(0.35), radius: 8, y: 3)
    }
}

struct StatusPill: View {
    let state: RunnerState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 6, height: 6)
            Text(state.title)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(state.tone.fill, in: Capsule())
    }
}

/// Start/Stop, Restart and Clean, with confirmations for anything that cancels a job or deletes files.
let notServiceHelp = "Started with run.sh, not installed as a service: stop or restart it where it runs"
func otherUserHelp(_ r: Runner) -> String { "Belongs to \(r.owner): only they or an administrator can control it" }

struct RunnerActions: View {
    @EnvironmentObject var store: Store
    let runner: Runner
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case stop, restart, clean
        var id: Self { self }
    }

    var body: some View {
        let r = runner, working = store.working.contains(r.dir)
        HStack(spacing: 8) {
            Group {
                if r.state == .stopped {
                    Button { store.start(r) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.okFill)
                } else {
                    Button { confirm = .stop } label: { Label("Stop", systemImage: "stop.fill") }
                }
                Button { if r.state == .busy { confirm = .restart } else { store.restart(r) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
            }
            .disabled(!r.isService || r.isOtherUsers)
            .help(r.isOtherUsers ? otherUserHelp(r) : r.isService ? "" : notServiceHelp)
            Button { confirm = .clean } label: { Label("Clean…", systemImage: "trash") }
                .disabled(r.state == .busy || r.isOtherUsers)
                .help(r.isOtherUsers ? otherUserHelp(r) : r.state == .busy ? "Not available while a job is running" : "Delete checkouts and build outputs in _work")
            if working { ProgressView().controlSize(.small).padding(.leading, 4) }
        }
        .buttonStyle(.bordered)
        .disabled(working)
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            switch c {
            case .stop: Button(r.state == .busy ? "Stop and cancel job" : "Stop runner", role: .destructive) { store.stop(r) }
            case .restart: Button("Restart and cancel job", role: .destructive) { store.restart(r) }
            case .clean: Button("Delete \(fileSize(store.cleanableBytes(r)))", role: .destructive) { store.cleanWorkspace(r) }
            }
        } message: { c in
            switch c {
            case .stop where r.state != .busy: Text("\(r.org) goes offline and won't pick up jobs until you press Start.")
            case .stop, .restart: Text("\(r.org) is running “\(r.current?.name ?? "a job")”. It will be cancelled and fail on GitHub.")
            case .clean: Text("Deletes the repo checkouts, build outputs and temp files in \(r.dir)/_work. The toolchain cache in _tool is kept. The next job re-clones from scratch.")
            }
        }
    }

    private var dialogTitle: String {
        switch confirm {
        case .stop: return runner.state == .busy ? "Stop \(runner.org) while it is busy?" : "Stop \(runner.org)?"
        case .restart: return "Restart \(runner.org) while it is busy?"
        case .clean: return "Clean \(runner.org) workspace?"
        case nil: return ""
        }
    }
}

struct JobList: View {
    let jobs: [Job]
    var showRunner = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { i, j in
                HStack(spacing: 12) {
                    Image(systemName: icon(j.result)).font(.title3).foregroundStyle(color(j.result))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(j.name).fontWeight(.medium).lineLimit(1)
                        Text((showRunner ? j.runner + " · " : "") + "\(j.result) · \(ago(j.end))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(duration(j.duration), systemImage: "clock").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if let url = j.url {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open this run on GitHub")
                    }
                }
                .padding(.vertical, 10)
                if i < jobs.count - 1 { Divider() }
            }
            if jobs.isEmpty { Text("No jobs yet").foregroundStyle(.secondary).padding() }
        }
        .padding(.horizontal, 4)
        .card(padding: 12)
    }

    private func icon(_ r: String) -> String {
        r == "Succeeded" ? "checkmark.circle.fill" : r == "Failed" ? "xmark.circle.fill" : r == "Canceled" || r == "Cancelled" ? "minus.circle.fill" : "exclamationmark.circle.fill"
    }

    private func color(_ r: String) -> Color {
        r == "Succeeded" ? .okMark : r == "Failed" ? .dangerMark : r == "Canceled" || r == "Cancelled" ? .secondary : .warnMark
    }
}
