import Charts
import SwiftUI

struct UsageFigure: View {
    let title: String, traffic: Traffic
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(fileSize(traffic.total)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("↓ \(fileSize(traffic.rx))  ↑ \(fileSize(traffic.tx))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct NetworkSummaryCard: View {
    @EnvironmentObject var net: NetworkUsage
    @State private var hover = false

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        NavigationLink(value: Route.network) {
            HStack(spacing: 16) {
                ToneBadge(icon: connectionIcon(net.current), tone: .teal, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(net.current ?? "Offline").font(.headline).lineLimit(1)
                    Text("↓ \(speed(net.rate.rx))   ↑ \(speed(net.rate.tx))").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                UsageFigure(title: "Runners today", traffic: net.runnerNames.reduce(Traffic()) { $0 + net.total(since: today, runner: $1) })
                UsageFigure(title: "Mac today", traffic: net.total(since: today)).padding(.leading, 24)
                UsageFigure(title: "Mac this month", traffic: net.total(since: cal.dateInterval(of: .month, for: Date())!.start)).padding(.leading, 24)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.tealText.opacity(hover ? 0.55 : 0), lineWidth: 1.5))
        .scaleEffect(hover ? 1.006 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
    }
}

/// Network card on a runner's screen: today's usage and the last 24 hours.
struct RunnerNetworkCard: View {
    @EnvironmentObject var net: NetworkUsage
    let org: String

    var body: some View {
        let cal = Calendar.current
        let today = net.total(since: cal.startOfDay(for: Date()), runner: org)
        let month = net.total(since: cal.dateInterval(of: .month, for: Date())!.start, runner: org)
        let rate = net.runnerRate[org] ?? Traffic()
        let last24 = buckets(net.hourly(runner: org), .hourly)
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: "Network", icon: "network").font(.subheadline.weight(.medium)).foregroundStyle(Color.tealText)
            Text(fileSize(today.total)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("today · ↓ \(fileSize(today.rx)) ↑ \(fileSize(today.tx)) · \(fileSize(month.total)) this month")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Chart(last24, id: \.start) { b in
                BarMark(x: .value("Hour", b.start, unit: .hour), y: .value("Data", Double(b.traffic.total)))
                    .foregroundStyle(Color.tealMark.gradient)
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : fileSize(Int64(d))) } }
                }
            }
            .frame(height: 120).padding(.top, 6)
            Text("Last 24 hours · now ↓ \(speed(rate.rx)) ↑ \(speed(rate.tx))").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

struct UsagePoint: Identifiable {
    let id = UUID()
    let start: Date, series: String, bytes: Double
}

enum UsageGrouping: String, CaseIterable, Identifiable {
    case connection = "Connections", runner = "Runners"
    var id: String { rawValue }
}

typealias UsageSeries = (name: String, buckets: [(start: Date, traffic: Traffic)])

struct NetworkView: View {
    @EnvironmentObject var net: NetworkUsage
    @EnvironmentObject var store: Store
    @State private var period = UsagePeriod.daily
    @State private var grouping = UsageGrouping.connection
    @State private var connection: String?  // nil = all connections
    @State private var runner: String?      // focused row in the Runners view
    @State private var selected: Date?
    private let palette = Color.series
    static let everythingElse = "Everything else"

    /// One series per connection, or per runner plus "Everything else" (whole Mac minus runners), each bucketed for the period.
    private func series() -> [UsageSeries] {
        switch grouping {
        case .connection:
            return net.connections.filter { connection == nil || $0 == connection }.map { ($0, buckets(net.hours[$0] ?? [:], period)) }
        case .runner:
            let names = (store.runners.map(\.org) + net.runnerNames).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let runners: [UsageSeries] = names.map { ($0, buckets(net.hourly(runner: $0, connection: connection), period)) }
            let mac = buckets(net.hourly(connection: connection), period)
            let rest = mac.indices.map { i -> (start: Date, traffic: Traffic) in
                let used = runners.reduce(Traffic()) { $0 + $1.buckets[i].traffic }
                return (mac[i].start, Traffic(rx: max(0, mac[i].traffic.rx - used.rx), tx: max(0, mac[i].traffic.tx - used.tx)))
            }
            return runners + [(Self.everythingElse, rest)]
        }
    }

    var body: some View {
        let groups = series()
        let order = grouping == .connection ? net.connections : groups.map(\.name)  // stable colors while filtering
        let color = { (name: String) -> Color in
            name == Self.everythingElse ? .neutralMark : self.palette[(order.firstIndex(of: name) ?? 0) % self.palette.count]
        }
        let focus = grouping == .runner ? runner : nil
        let shown = focus.map { f in groups.filter { $0.name == f } } ?? groups
        let directional = focus != nil || (grouping == .connection && connection != nil)
        let total = shown.flatMap(\.buckets).reduce(Traffic()) { $0 + $1.traffic }
        let points: [UsagePoint] = directional
            ? shown.flatMap { s in s.buckets.flatMap { [UsagePoint(start: $0.start, series: "Download", bytes: Double($0.traffic.rx)),
                                                        UsagePoint(start: $0.start, series: "Upload", bytes: Double($0.traffic.tx))] } }
            : shown.flatMap { s in s.buckets.map { UsagePoint(start: $0.start, series: s.name, bytes: Double($0.traffic.total)) } }
        let hovered = selected.flatMap { sel in buckets([:], period).last { $0.start <= sel }?.start }
        let hoveredTraffic = hovered.map { h in shown.reduce(Traffic()) { $0 + ($1.buckets.first { $0.start == h }?.traffic ?? Traffic()) } }
        let rows = groups.map { (name: $0.name, traffic: $0.buckets.reduce(Traffic()) { $0 + $1.traffic }) }
        let grand = max(rows.reduce(0) { $0 + $1.traffic.total }, 1)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    ToneBadge(icon: connectionIcon(net.current), tone: .teal, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Network").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(net.current ?? "Offline")  ·  ↓ \(speed(net.rate.rx))  ↑ \(speed(net.rate.tx))")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    OpenAtLoginToggle().toggleStyle(.switch)
                }

                if !net.canReadWiFiNames {
                    HStack(spacing: 12) {
                        Image(systemName: "location.slash.fill").font(.title2).foregroundStyle(Color.warnText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wi-Fi network names are hidden").fontWeight(.semibold)
                            Text("macOS only shares the Wi-Fi name with apps that have Location access. Until it's allowed, Wi-Fi usage is recorded as “Wi-Fi · Name hidden”. Your location itself is never read.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Allow Location Access") { net.requestLocation() }.buttonStyle(.borderedProminent).tint(.warnFill)
                    }
                    .padding(14)
                    .background(Color.warnText.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack(spacing: 12) {
                    Picker("Period", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("Group by", selection: $grouping) {
                        ForEach(UsageGrouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Picker("Connection", selection: $connection) {
                        Text("All connections").tag(String?.none)
                        Divider()
                        ForEach(net.connections, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .fixedSize()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    StatTile(title: "Downloaded", value: fileSize(total.rx), icon: "arrow.down", tone: .teal)
                    StatTile(title: "Uploaded", value: fileSize(total.tx), icon: "arrow.up", tone: .purple)
                    StatTile(title: "\(focus ?? "Total") · \(period.caption.lowercased())", value: fileSize(total.total), icon: "sum", tone: .info)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        HelpLabel(title: "Data usage").font(.headline)
                        Spacer()
                        if let hovered, let t = hoveredTraffic {
                            Text("\(hovered.formatted(period.format)): \(fileSize(t.total))   ↓ \(fileSize(t.rx))  ↑ \(fileSize(t.tx))")
                                .font(.callout).monospacedDigit()
                        } else {
                            Text(period.caption).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Chart(points) { p in
                        BarMark(x: .value("Time", p.start, unit: period.unit), y: .value("Data", p.bytes))
                            .foregroundStyle(by: .value("Series", p.series))
                            .cornerRadius(3)
                            .opacity(hovered == nil || hovered == p.start ? 1 : 0.4)
                    }
                    .chartForegroundStyleScale(domain: directional ? ["Download", "Upload"] : groups.map(\.name),
                                               range: directional ? [Color.tealMark, Color.purpleMark] : groups.map { color($0.name) })
                    .chartXSelection(value: $selected)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: period.unit, count: period == .hourly ? 3 : period == .daily ? 5 : 1)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: period.format)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : fileSize(Int64(d))) } }
                        }
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 260)
                    if total.total == 0 {
                        Text("Nothing recorded for this period yet. Tracking started when this version of the app first ran.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 4) {
                    HelpLabel(title: grouping == .runner ? "By runner" : "By connection").font(.headline).padding(.bottom, 6)
                    ForEach(rows, id: \.name) { row in
                        let isFocused = grouping == .runner ? runner == row.name : connection == row.name
                        Button {
                            if grouping == .runner { runner = isFocused ? nil : row.name } else { connection = isFocused ? nil : row.name }
                        } label: {
                            HStack(spacing: 12) {
                                IconBadge(icon: grouping == .connection ? connectionIcon(row.name) : row.name == Self.everythingElse ? "macbook" : "server.rack",
                                          color: color(row.name), size: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.name).fontWeight(.medium).lineLimit(1)
                                    GeometryReader { g in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.08))
                                            Capsule().fill(color(row.name)).frame(width: max(4, g.size.width * Double(row.traffic.total) / Double(grand)))
                                        }
                                    }
                                    .frame(height: 5)
                                }
                                Spacer(minLength: 16)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(fileSize(row.traffic.total)).fontWeight(.semibold).monospacedDigit()
                                    Text("↓ \(fileSize(row.traffic.rx))  ↑ \(fileSize(row.traffic.tx))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 150, alignment: .trailing)
                            }
                            .padding(10)
                            .background(isFocused ? color(row.name).opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isFocused ? "Show all" : "Show only \(row.name)")
                    }
                    if rows.isEmpty { Text("Nothing recorded yet.").foregroundStyle(.secondary) }
                }
                .card()
            }
            .padding(28)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop(tint: .tealMark))
        .navigationTitle("Network")
        .onChange(of: grouping) { _, _ in runner = nil }
    }
}
