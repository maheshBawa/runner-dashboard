import SwiftUI

/// Find Runners: a radar sweeps while runners anywhere on the Mac turn up, then the user picks which to add.
struct FindRunnersSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var found: [FoundRunner] = []
    @State private var picked: Set<String> = []
    @State private var searching: String? = "Checking running runners"  // nil once the search is done
    @State private var task: Task<Void, Never>?

    var body: some View {
        let shown = Set(store.runners.map(\.dir))
        let new = found.filter { !shown.contains($0.dir) }.count
        VStack(spacing: 16) {
            Text(searching != nil ? "Finding Runners…" : new == 0 ? "No New Runners" : "Found \(new) New Runner\(new == 1 ? "" : "s")")
                .font(.title2.bold())
            RadarView(blips: found.map { (id: $0.dir, label: $0.org, dim: shown.contains($0.dir)) }, sweeping: searching != nil)
                .frame(width: 260, height: 260)
            Text(searching ?? "Searched running runners, launch agents, your home folder (except Desktop, Documents and Downloads), /opt, /usr/local and /Users/Shared.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
            if !found.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(found) { row($0, shown: shown.contains($0.dir)) }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack {
                Spacer()
                Button(searching != nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.count) Runner\(picked.count == 1 ? "" : "s")", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: start)
        .onDisappear { task?.cancel() }
    }

    private func row(_ f: FoundRunner, shown: Bool) -> some View {
        HStack(spacing: 10) {
            if shown {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Toggle(f.org, isOn: Binding(get: { picked.contains(f.dir) }, set: { if $0 { picked.insert(f.dir) } else { picked.remove(f.dir) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(f.org).font(.headline)
                Text((f.dir as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(shown ? "In dashboard" : f.source.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func start() {
        let began = Date()
        task = Task.detached(priority: .userInitiated) {
            searchRunners(found: { f in
                DispatchQueue.main.async {
                    withAnimation(.spring(duration: 0.4)) { found.append(f) }
                    if !store.runners.contains(where: { $0.dir == f.dir }) { picked.insert(f.dir) }
                }
            }, searching: { s in DispatchQueue.main.async { searching = s } })
            // At least one full sweep, so a quick search still reads as a scan.
            let rest = 2.4 - Date().timeIntervalSince(began)
            if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1e9)) }
            await MainActor.run { withAnimation { searching = nil } }
        }
    }

    private func add() {
        let d = UserDefaults.standard
        d.set((d.stringArray(forKey: Pref.addedRunners) ?? []) + picked.sorted(), forKey: Pref.addedRunners)
        store.refresh()
        dismiss()
    }
}

/// Rings, a beam that sweeps while `sweeping`, and a blip per runner (grey when it's already on the dashboard).
struct RadarView: View {
    let blips: [(id: String, label: String, dim: Bool)]
    let sweeping: Bool
    @State private var began = Date()

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            TimelineView(.animation(paused: !sweeping)) { t in
                let angle = Angle.degrees(t.date.timeIntervalSince(began) / 2.4 * 360)
                ZStack {
                    Circle().fill(Color.okMark.opacity(0.07))
                    ForEach(1...3, id: \.self) { i in
                        Circle().stroke(Color.okMark.opacity(0.3), lineWidth: 1).frame(width: 2 * r * Double(i) / 3, height: 2 * r * Double(i) / 3)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: 2 * r, y: r))
                        p.move(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: r, y: 2 * r))
                    }
                    .stroke(Color.okMark.opacity(0.2), lineWidth: 1)
                    if sweeping {
                        // The trail fades in over the quarter turn behind the beam, which leads clockwise.
                        Circle()
                            .fill(AngularGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.75),
                                                          .init(color: Color.okMark.opacity(0.45), location: 1)], center: .center))
                            .rotationEffect(angle)
                        Path { p in p.move(to: CGPoint(x: r, y: r)); p.addLine(to: CGPoint(x: 2 * r, y: r)) }
                            .stroke(Color.okMark, lineWidth: 2)
                            .rotationEffect(angle)
                    }
                    ForEach(Array(blips.enumerated()), id: \.element.id) { i, b in
                        // Golden-angle spiral: blips spread out, and each keeps its spot as more turn up.
                        let a = Double(i) * 2.39996, d = r * (0.35 + 0.5 * (Double(i) * 0.618).truncatingRemainder(dividingBy: 1))
                        RadarBlip(label: b.label, dim: b.dim).position(x: r + d * cos(a), y: r + d * sin(a))
                    }
                }
                .frame(width: 2 * r, height: 2 * r)
            }
        }
    }
}

private struct RadarBlip: View {
    let label: String, dim: Bool
    @State private var ping = false

    var body: some View {
        let c = dim ? Color.secondary : Color.okMark
        ZStack {
            Circle().stroke(c, lineWidth: 1.5).frame(width: 10, height: 10).scaleEffect(ping ? 3.5 : 1).opacity(ping ? 0 : 0.9)
            Circle().fill(c).frame(width: 9, height: 9).shadow(color: c, radius: 4)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).fixedSize().offset(y: 14)
        }
        .transition(.scale.combined(with: .opacity))
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { ping = true } }
    }
}
