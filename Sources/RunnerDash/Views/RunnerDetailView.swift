import AppKit
import Charts
import SwiftUI

struct MetricCard: View {
    let title: String, icon: String, tone: Tone, value: String, detail: String
    let samples: [Sample]
    let metric: KeyPath<Sample, Double>
    let yMax: Double
    var caption: String? = nil  // default: the live window
    let axisLabel: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: title, icon: icon).font(.subheadline.weight(.medium)).foregroundStyle(tone.text)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText()).animation(.default, value: value)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            chart.frame(height: 120).padding(.top, 6)
            Text(caption ?? (samples.count > 1 ? "Live · last \(duration(samples.last!.date.timeIntervalSince(samples.first!.date)))" : "Collecting…"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var color: Color { tone.mark }

    private var chart: some View {
        Chart(samples) { s in
            AreaMark(x: .value("Time", s.date), y: .value(title, s[keyPath: metric]))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", s.date), y: .value(title, s[keyPath: metric]))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)) } }
            }
        }
    }
}

struct StorageCard: View {
    let dir: String
    let items: [StorageItem]?
    var oldBytes: Int64? = nil
    var canRemoveOld = false
    var removeOld: () -> Void = {}
    @State private var confirmRemove = false

    var body: some View {
        let total = items?.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: "Storage", icon: "internaldrive").font(.subheadline.weight(.medium)).foregroundStyle(Color.warnText)
            Text(items == nil ? "Measuring…" : fileSize(total)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("on disk in \((dir as NSString).abbreviatingWithTildeInPath)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let items {
                Chart(items) { i in
                    BarMark(x: .value("Size", Double(i.bytes)), y: .value("Folder", "storage"))
                        .foregroundStyle(by: .value("Kind", i.name))
                }
                .chartForegroundStyleScale(domain: storageKinds.map(\.name), range: storageKinds.map(\.color))
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .frame(height: 12).clipShape(Capsule())
                .padding(.vertical, 8)
                VStack(spacing: 5) {
                    ForEach(Array(zip(items, storageKinds)), id: \.0.id) { item, kind in
                        HStack(spacing: 8) {
                            Circle().fill(kind.color).frame(width: 8, height: 8)
                            Text(item.name)
                            Spacer()
                            Text(fileSize(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(.top, 8)
            }
            if let oldBytes, oldBytes > 0 {
                Button("Remove old versions (\(fileSize(oldBytes)))…") { confirmRemove = true }
                    .controlSize(.small)
                    .padding(.top, 6)
                    .disabled(!canRemoveOld)
                    .help(canRemoveOld ? "Delete previous runner versions, the installer and update downloads" : "Not available while a job is running")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .confirmationDialog("Remove old runner versions?", isPresented: $confirmRemove) {
            Button("Delete \(fileSize(oldBytes))", role: .destructive, action: removeOld)
        } message: {
            Text("Deletes the previous bin/externals versions left by self-updates, the installer archive and the finished update download in \((dir as NSString).abbreviatingWithTildeInPath). The version the runner uses now isn't touched.")
        }
    }
}

struct StatTile: View {
    let title: String, value: String, icon: String, tone: Tone
    var body: some View {
        HStack(spacing: 12) {
            ToneBadge(icon: icon, tone: tone, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HelpLabel(title: title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

struct HealthCard: View {
    let runner: Runner
    var body: some View {
        let r = runner
        let warn = r.lastEvent.map { $0.msg.range(of: "error|fail|exception", options: [.regularExpression, .caseInsensitive]) != nil } ?? false
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            row("Service", r.service.map { $0.pid != nil ? "loaded · pid \($0.pid!)" : "not running · exit \($0.status)" } ?? "not loaded",
                r.service?.pid != nil ? .okText : .dangerText)
            Divider()
            row("Listener", r.listener.map { "up \(duration(seconds(etime: $0.etime))) · \(String(format: "%.1f", $0.cpu))% · \(memSize(Double($0.rss)))" } ?? "not running",
                r.listener == nil ? .dangerText : .primary)
            Divider()
            row("Job load", r.jobLoad.map { "\(Int($0.cpu))% CPU · \(memSize(Double($0.rss))) · \($0.count) procs" } ?? "—")
            Divider()
            row("Diag activity", ago(r.diagActivity))
            Divider()
            row("Last event", r.lastEvent.map { "\(ago($0.date)) · \($0.msg)" } ?? "—", warn ? .warnText : .primary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func row(_ key: String, _ value: String, _ color: Color = .primary) -> some View {
        GridRow {
            HelpLabel(title: key).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).lineLimit(1).truncationMode(.tail).help(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct RunnerDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var automation: Automation
    let dir: String
    @State private var follow = true
    @State private var week = false  // resources: live window or 7 days of hourly averages

    var body: some View {
        if let r = store.runners.first(where: { $0.dir == dir }) {
            content(r)
        } else {
            ContentUnavailableView("Runner not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ r: Runner) -> some View {
        let samples = week ? store.resources.samples(r.org) : store.history[dir] ?? []
        let caption = week ? "Hourly average · last 7 days" : nil
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let cpuNow = r.cpu / cores
        let peakCPU = samples.map(\.cpu).max() ?? 0
        let peakRSS = samples.map(\.rss).max() ?? 0
        let total = r.jobs.count
        let durations = r.jobs.compactMap(\.duration)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    RunnerIcon(state: r.state, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(r.org).font(.system(size: 28, weight: .bold, design: .rounded))
                            StatusPill(state: r.state)
                            if let latest = automation.latestRunnerVersion, isOlder(r.version, than: latest) { UpdatePill(latest: latest) }
                        }
                        HStack(spacing: 6) {
                            Text("\(r.name) · v\(r.version)")
                            if let url = URL(string: r.url + "/settings/actions/runners") {
                                Text("·")
                                Link("Open on GitHub", destination: url)
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RunnerActions(runner: r).controlSize(.large)
                }

                if r.state == .busy {
                    HStack(spacing: 10) {
                        Image(systemName: "hammer.fill").symbolEffect(.pulse)
                        Text("Running \(r.current?.name ?? "a job")").fontWeight(.semibold)
                        Spacer()
                        if let start = r.current?.start { Text(duration(Date().timeIntervalSince(start))).monospacedDigit() }
                        if let url = r.current?.url { Link("Open run", destination: url).fontWeight(.semibold) }
                    }
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(14)
                    .background(LinearGradient(colors: [Tone.info.tileTop, Tone.info.fill], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack {
                    SectionHeader(title: "Resources")
                    Spacer()
                    Picker("Range", selection: $week) {
                        Text("Live").tag(false)
                        Text("7 days").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], spacing: 16) {
                    MetricCard(title: "CPU", icon: "cpu", tone: .info, value: pct(cpuNow),
                               detail: String(format: "%.2f cores · %d processes", r.cpu / 100, r.procCount) + (r.simulatorIncluded ? " · incl. Simulator" : ""),
                               samples: samples, metric: \.cpu, yMax: max(10, peakCPU * 1.3), caption: caption) { "\(Int($0))%" }
                    MetricCard(title: "Memory", icon: "memorychip", tone: .purple, value: memSize(Double(r.rss)),
                               detail: "\(pct(Double(r.rss) / store.sys.memTotal * 100)) of \(memSize(store.sys.memTotal)) RAM",
                               samples: samples, metric: \.rss, yMax: max(256 * 1_048_576, peakRSS * 1.3), caption: caption) { $0 == 0 ? "0" : memSize($0) }
                    RunnerNetworkCard(org: r.org)
                    StorageCard(dir: r.dir, items: store.storage[r.dir], oldBytes: store.oldVersionBytes(r),
                                canRemoveOld: r.state != .busy && !store.working.contains(r.dir)) { store.removeOldVersions(r) }
                }

                SectionHeader(title: "Health").padding(.top, 6)
                HStack(alignment: .top, spacing: 16) {
                    HealthCard(runner: r)
                    VStack(spacing: 12) {
                        StatTile(title: "Jobs 24h / total", value: "\(r.jobs.filter { ($0.end ?? .distantPast) > Date().addingTimeInterval(-86400) }.count) / \(total)",
                                 icon: "list.bullet.rectangle", tone: .info)
                        StatTile(title: "Success rate", value: total == 0 ? "—" : "\(100 * r.jobs.filter { $0.result == "Succeeded" }.count / total)%",
                                 icon: "checkmark.seal.fill", tone: .ok)
                        StatTile(title: "Avg duration", value: durations.isEmpty ? "—" : duration(durations.reduce(0, +) / Double(durations.count)),
                                 icon: "timer", tone: .warn)
                    }
                    .frame(width: 270)
                }

                HelpLabel(title: "Build times").font(.title3.weight(.semibold)).padding(.top, 10)
                BuildTimesCard(jobs: r.jobs)

                SectionHeader(title: "Recent jobs").padding(.top, 6)
                JobList(jobs: Array(r.jobs.prefix(10)))

                HStack {
                    SectionHeader(title: "Logs")
                    Spacer()
                    Picker("Log", selection: $store.logKind) {
                        ForEach(LogKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.logKind == .service ? r.logDir : r.dir + "/_diag")
                    } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
                .padding(.top, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(store.logText.isEmpty ? "(empty)" : store.logText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 380)
                    .padding(14)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .onChange(of: store.logText) { _, _ in if follow { proxy.scrollTo("end", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .padding(28)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop(tint: r.state.tone.mark))
        .navigationTitle(r.org)
        .onAppear { store.logRunner = dir }
    }
}

struct UpdatePill: View {
    let latest: String
    var body: some View {
        Link(destination: URL(string: "https://github.com/actions/runner/releases/tag/v\(latest)")!) {
            Label("v\(latest) available", systemImage: "arrow.up.circle.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.warnFill, in: Capsule())
        .help("Runners update themselves when GitHub tells them to, usually just before their next job. Click for the release notes.")
    }
}

/// How long each kind of job takes over time. Successful runs only: failures stop early and would skew it.
struct BuildTimesCard: View {
    let jobs: [Job]  // newest first

    var body: some View {
        let runs = Array(jobs.filter { $0.result == "Succeeded" && $0.duration != nil && $0.end != nil }.prefix(80).reversed())
        let counts = Dictionary(grouping: runs, by: \.name).mapValues(\.count)
        let names = Array(counts.keys.sorted { counts[$0]! > counts[$1]! }.prefix(5))
        let shown = runs.filter { names.contains($0.name) }
        VStack(alignment: .leading, spacing: 12) {
            if shown.isEmpty {
                Text("No successful jobs yet.").foregroundStyle(.secondary)
            } else {
                Chart(shown) { j in
                    LineMark(x: .value("Finished", j.end!), y: .value("Minutes", j.duration! / 60))
                        .foregroundStyle(by: .value("Job", j.name))
                        .interpolationMethod(.linear)  // smoothing invents curves across gaps with no jobs
                    PointMark(x: .value("Finished", j.end!), y: .value("Minutes", j.duration! / 60))
                        .foregroundStyle(by: .value("Job", j.name))
                        .symbolSize(22)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))m") } }
                    }
                }
                .chartForegroundStyleScale(domain: names, range: names.indices.map { Color.series[$0 % Color.series.count] })
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 200)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Job", "Runs", "Average", "Last", "Last vs average"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(names, id: \.self) { name in
                        let times = runs.filter { $0.name == name }.compactMap(\.duration)
                        let avg = times.reduce(0, +) / Double(times.count), last = times.last ?? avg
                        let change = avg > 0 ? (last - avg) / avg : 0
                        GridRow {
                            Text(name).lineLimit(1)
                            Text("\(times.count)").monospacedDigit()
                            Text(duration(avg)).monospacedDigit()
                            Text(duration(last)).monospacedDigit()
                            Text(change > 0.1 ? "▲ \(Int(change * 100))% slower" : change < -0.1 ? "▼ \(Int(-change * 100))% faster" : "≈ usual")
                                .foregroundStyle(change > 0.1 ? Color.warnText : change < -0.1 ? Color.okText : Color.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
