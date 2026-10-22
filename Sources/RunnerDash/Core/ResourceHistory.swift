import AppKit

struct ResourceAgg: Codable {
    var cpuSum = 0.0, cpuMax = 0.0, rssSum = 0.0, rssMax = 0.0, n = 0
}

/// Hourly CPU/RAM averages and peaks per runner, kept 30 days, so the runner screen can show more than the live window.
final class ResourceHistory {
    private(set) var hours: [String: [Int: ResourceAgg]] = [:]  // runner -> local hour start (unix s) -> aggregate
    private var savedAt = Date()
    private let file = appSupportFile("resource-history.json")

    init() {
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode([String: [Int: ResourceAgg]].self, from: data) {
                hours = saved
            } else {  // keep an unreadable history file instead of overwriting it
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.save() }
    }

    func record(_ runners: [Runner]) {
        let hour = Int(Calendar.current.dateInterval(of: .hour, for: Date())!.start.timeIntervalSince1970)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        for r in runners {
            var a = hours[r.org]?[hour] ?? ResourceAgg()
            let cpu = r.cpu / cores, rss = Double(r.rss)
            (a.cpuSum, a.cpuMax, a.rssSum, a.rssMax, a.n) = (a.cpuSum + cpu, max(a.cpuMax, cpu), a.rssSum + rss, max(a.rssMax, rss), a.n + 1)
            hours[r.org, default: [:]][hour] = a
        }
        if Date().timeIntervalSince(savedAt) > 300 { save() }
    }

    /// Hourly averages for the last `days`, oldest first.
    func samples(_ org: String, days: Int = 7) -> [Sample] {
        let from = Int(Date().timeIntervalSince1970) - days * 86400
        return (hours[org] ?? [:]).filter { $0.key >= from }.sorted { $0.key < $1.key }.map {
            Sample(date: Date(timeIntervalSince1970: TimeInterval($0.key)), cpu: $0.value.cpuSum / Double($0.value.n), rss: $0.value.rssSum / Double($0.value.n))
        }
    }

    func save() {
        let cutoff = Int(Date().timeIntervalSince1970) - 30 * 86400
        hours = hours.mapValues { $0.filter { $0.key >= cutoff } }
        if let data = try? JSONEncoder().encode(hours) { try? data.write(to: file, options: .atomic) }
        savedAt = Date()
    }
}
