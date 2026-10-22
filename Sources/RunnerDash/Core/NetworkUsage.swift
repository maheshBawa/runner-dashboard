import AppKit
import CoreLocation
import CoreWLAN
import SwiftUI
import SystemConfiguration

struct Traffic: Codable, Equatable {
    var rx: Int64 = 0, tx: Int64 = 0
    var total: Int64 { rx + tx }
    static func + (a: Traffic, b: Traffic) -> Traffic { Traffic(rx: a.rx + b.rx, tx: a.tx + b.tx) }
    static func += (a: inout Traffic, b: Traffic) { a = a + b }
}

struct UsageRow: Codable {
    let hour: Int, connection: String, traffic: Traffic
    let source: String?  // nil = whole Mac, else the runner
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case hourly = "Hourly", daily = "Daily", monthly = "Monthly"
    var id: String { rawValue }
    var unit: Calendar.Component { self == .hourly ? .hour : self == .daily ? .day : .month }
    var count: Int { self == .hourly ? 24 : self == .daily ? 30 : 12 }
    var caption: String { self == .hourly ? "Last 24 hours" : self == .daily ? "Last 30 days" : "Last 12 months" }
    var format: Date.FormatStyle {
        self == .hourly ? .dateTime.hour() : self == .daily ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year(.twoDigits)
    }
}

/// Bytes since the previous reading. Interface counters restart from 0 after a reboot or interface reset.
func delta(_ prev: Traffic, _ now: Traffic) -> Traffic {
    Traffic(rx: now.rx >= prev.rx ? now.rx - prev.rx : now.rx, tx: now.tx >= prev.tx ? now.tx - prev.tx : now.tx)
}

/// Sums hourly usage (keyed by local hour start, unix seconds) into the last `period.count` hours/days/months, oldest first.
func buckets(_ hours: [Int: Traffic], _ period: UsagePeriod, now: Date = Date()) -> [(start: Date, traffic: Traffic)] {
    let cal = Calendar.current
    let current = cal.dateInterval(of: period.unit, for: now)!.start
    let starts = (0..<period.count).reversed().map { cal.date(byAdding: period.unit, value: -$0, to: current)! }
    var sums = Dictionary(uniqueKeysWithValues: starts.map { ($0, Traffic()) })
    let from = Int(starts[0].timeIntervalSince1970)
    for (hour, t) in hours where hour >= from {
        sums[cal.dateInterval(of: period.unit, for: Date(timeIntervalSince1970: TimeInterval(hour)))!.start]? += t
    }
    return starts.map { ($0, sums[$0]!) }
}

/// 64-bit byte counters per interface since boot (sysctl NET_RT_IFLIST2).
func interfaceCounters() -> [String: Traffic] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
    var out: [String: Traffic] = [:]
    buf.withUnsafeBytes { raw in
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= len {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(msg.ifm_index), &name) != nil {
                    out[String(cString: name)] = Traffic(rx: Int64(msg.ifm_data.ifi_ibytes), tx: Int64(msg.ifm_data.ifi_obytes))
                }
            }
            guard header.ifm_msglen > 0 else { break }
            offset += Int(header.ifm_msglen)
        }
    }
    return out
}

/// Physical connections, e.g. ["en0": "Wi-Fi", "en7": "iPhone USB"]. Bridges are skipped: their traffic is counted on member ports.
func hardwarePorts() -> [String: String] {
    var out: [String: String] = [:], port = ""
    for line in run("/usr/sbin/networksetup", ["-listallhardwareports"]).out.split(separator: "\n") {
        if line.hasPrefix("Hardware Port: ") {
            port = String(line.dropFirst(15))
        } else if line.hasPrefix("Device: "), !port.contains("Bridge") {
            out[String(line.dropFirst(8))] = port
        }
    }
    return out
}

func speed(_ bytesPerSecond: Int64) -> String { fileSize(bytesPerSecond) + "/s" }

func connectionIcon(_ name: String?) -> String {
    guard let name else { return "wifi.slash" }
    return name.hasPrefix("Wi-Fi") ? "wifi" : name.contains("iPhone") ? "iphone" : name.contains("Thunderbolt") ? "bolt.horizontal" : "cable.connector"
}

/// Bytes a process gained since the previous reading. nettop's per-process totals only grow; a drop means it forgot
/// closed sockets, so count nothing rather than double count.
func growth(_ prev: Traffic, _ now: Traffic) -> Traffic {
    Traffic(rx: max(0, now.rx - prev.rx), tx: max(0, now.tx - prev.tx))
}

/// pid -> parent pid for every process, straight from the kernel.
func parentMap() -> [Int: Int] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [:] }
    size += size / 4  // room for processes started in between
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [:] }
    var out: [Int: Int] = [:]
    for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) { out[Int(p.kp_proc.p_pid)] = Int(p.kp_eproc.e_ppid) }
    return out
}

/// The runner whose process tree contains `pid`: follow parent links up to a runner listener (a root).
func owner(of pid: Int, parents: [Int: Int], roots: [Int: String]) -> String? {
    var p = pid
    for _ in 0..<64 {
        if let org = roots[p] { return org }
        guard let parent = parents[p], parent > 1, parent != p else { return nil }
        p = parent
    }
    return nil
}

/// One `nettop -P -L` CSV row, e.g. "Runner.Listener.2377,1234,567," -> (pid, bytes since the process started).
func parseNettopRow(_ line: Substring) -> (pid: Int, traffic: Traffic)? {
    let f = line.split(separator: ",", omittingEmptySubsequences: false)
    guard f.count >= 4, let rx = Int64(f[f.count - 3]), let tx = Int64(f[f.count - 2]) else { return nil }
    let name = f[0..<(f.count - 3)].joined(separator: ",")
    guard let dot = name.lastIndex(of: "."), let pid = Int(name[name.index(after: dot)...]) else { return nil }
    return (pid, Traffic(rx: rx, tx: tx))
}

/// Records bytes per connection per local hour while the app runs, for the whole Mac (interface counters) and per runner
/// (nettop per-process counters, attributed through each runner's process tree). Wi-Fi is split by network name (needs Location access).
final class NetworkUsage: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var hours: [String: [Int: Traffic]] = [:]                   // whole Mac: connection -> local hour start (unix s) -> bytes
    @Published private(set) var runnerHours: [String: [String: [Int: Traffic]]] = [:]  // runner -> connection -> local hour start -> bytes
    @Published private(set) var current: String?                                      // connection carrying traffic right now
    @Published private(set) var rate = Traffic()                                      // bytes/s on that connection
    @Published private(set) var runnerRate: [String: Traffic] = [:]                   // bytes/s per runner
    @Published private(set) var canReadWiFiNames = false
    private var last: [String: Traffic] = [:]
    private var lastAt = Date()
    private var ports: [String: String] = [:]
    private var portsAt = Date.distantPast
    private var savedAt = Date()
    private var timer: Timer?
    private let location = CLLocationManager()
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runner Dashboard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("network-usage.json")
    }()

    // nettop reader state: only touched on `queue`.
    private let queue = DispatchQueue(label: "runner-dashboard.nettop")
    private var nettop: Process?
    private var buffer = Data()
    private var sampleRows: [Int: Traffic] = [:]
    private var procLast: [Int: Traffic] = [:]
    private var parents: [Int: Int] = [:]
    private var roots: [Int: String] = [:]  // runner listener pid -> runner
    private var baselined = false
    private var pendingRunners: [String: Traffic] = [:]
    private var parentSnapshots: DispatchSourceTimer?

    override init() {
        super.init()
        if let data = try? Data(contentsOf: file) {
            if let rows = try? JSONDecoder().decode([UsageRow].self, from: data) {
                for r in rows {
                    if let source = r.source {
                        runnerHours[source, default: [:]][r.connection, default: [:]][r.hour] = r.traffic
                    } else {
                        hours[r.connection, default: [:]][r.hour] = r.traffic
                    }
                }
            } else {  // keep an unreadable history file instead of overwriting it
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            }
        }
        location.delegate = self
        locationManagerDidChangeAuthorization(location)
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        startNettop()
        let snapshots = DispatchSource.makeTimerSource(queue: queue)
        snapshots.schedule(deadline: .now(), repeating: .milliseconds(250))
        snapshots.setEventHandler { [weak self] in self?.rememberParents() }
        snapshots.resume()
        parentSnapshots = snapshots
        sample()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.save()
            self?.nettop?.terminationHandler = nil
            self?.nettop?.terminate()
        }
    }

    var connections: [String] { sortedByTotal(hours.mapValues { $0.values.reduce(0) { $0 + $1.total } }) }
    var runnerNames: [String] { sortedByTotal(runnerHours.mapValues { $0.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.total } } }) }

    private func sortedByTotal(_ totals: [String: Int64]) -> [String] { totals.keys.sorted { totals[$0]! > totals[$1]! } }

    /// Hourly bytes for the whole Mac or one runner, across all connections or just one.
    func hourly(runner: String? = nil, connection: String? = nil) -> [Int: Traffic] {
        var out: [Int: Traffic] = [:]
        for (c, byHour) in runner.map({ runnerHours[$0] ?? [:] }) ?? hours where connection == nil || c == connection {
            out.merge(byHour, uniquingKeysWith: +)
        }
        return out
    }

    func total(since: Date, runner: String? = nil) -> Traffic {
        let from = Int(since.timeIntervalSince1970)
        return hourly(runner: runner).filter { $0.key >= from }.values.reduce(Traffic(), +)
    }

    func setRunnerRoots(_ newRoots: [Int: String]) { queue.async { self.roots = newRoots } }

    func requestLocation() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        canReadWiFiNames = ![.notDetermined, .denied, .restricted].contains(manager.authorizationStatus)
    }

    // MARK: Whole-Mac counters (every 5 s)

    private func sample() {
        let refreshPorts = Date().timeIntervalSince(portsAt) > 60  // picks up adapters plugged in later
        DispatchQueue.global(qos: .utility).async {
            let counters = interfaceCounters()
            let ports = refreshPorts ? hardwarePorts() : nil
            let wifi = CWWiFiClient.shared().interface()
            let primary = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String
            let (wifiDevice, ssid) = (wifi?.interfaceName, wifi?.ssid())
            DispatchQueue.main.async { self.record(counters, ports, wifiDevice, ssid, primary) }
        }
    }

    private func record(_ counters: [String: Traffic], _ newPorts: [String: String]?, _ wifiDevice: String?, _ ssid: String?, _ primary: String?) {
        if let newPorts { (ports, portsAt) = (newPorts, Date()) }
        let now = Date()
        let hour = Int(Calendar.current.dateInterval(of: .hour, for: now)!.start.timeIntervalSince1970)
        let elapsed = max(now.timeIntervalSince(lastAt), 1)
        lastAt = now
        func name(_ device: String) -> String { device == wifiDevice ? "Wi-Fi · " + (ssid ?? "Name hidden") : ports[device] ?? device }

        var deltas: [String: Traffic] = [:]
        for (device, value) in counters where ports[device] != nil {
            if let prev = last[device] { deltas[device] = delta(prev, value) }
            last[device] = value
        }
        if deltas.values.contains(where: { $0.total > 0 }) {
            var updated = hours
            for (device, d) in deltas where d.total > 0 { updated[name(device), default: [:]][hour, default: Traffic()] += d }
            hours = updated
        }
        // The default route's interface. Behind a VPN that's a utun, so fall back to the busiest physical port.
        let active = primary.flatMap { ports[$0] != nil ? $0 : nil } ?? deltas.max { $0.value.total < $1.value.total }?.key
        current = active.map(name)
        let d = active.flatMap { deltas[$0] } ?? Traffic()
        rate = Traffic(rx: Int64(Double(d.rx) / elapsed), tx: Int64(Double(d.tx) / elapsed))

        // Runner traffic gathered by nettop since the last tick goes to the connection in use now.
        let pending = queue.sync { () -> [String: Traffic] in
            defer { pendingRunners = [:] }
            return pendingRunners
        }
        runnerRate = pending.mapValues { Traffic(rx: Int64(Double($0.rx) / elapsed), tx: Int64(Double($0.tx) / elapsed)) }
        if let connection = current, !pending.isEmpty {
            var updated = runnerHours
            for (org, d) in pending { updated[org, default: [:]][connection, default: [:]][hour, default: Traffic()] += d }
            runnerHours = updated
        }
        if now.timeIntervalSince(savedAt) > 60 { save() }
    }

    // MARK: Per-process counters (nettop, every second)

    /// nettop runs on a pseudo-terminal: into a pipe it buffers output for minutes (too late to match short-lived job
    /// processes to their runner), and when its stdin hits EOF it busy-loops at 100%+ CPU. A tty fixes both, but a tty
    /// also outlives us, so a small sh wrapper kills nettop within 2 s of this app exiting, even after a crash.
    private func startNettop() {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            exec 3<&0
            /usr/bin/nettop -P -L 0 -s 1 -x -n -t external -J bytes_in,bytes_out <&3 2>/dev/null &
            n=$!
            trap 'kill $n 2>/dev/null; exit 0' TERM INT HUP
            while kill -0 \(getpid()) 2>/dev/null && kill -0 $n 2>/dev/null; do sleep 2; done
            kill $n 2>/dev/null
            """]
        p.standardInput = tty
        p.standardOutput = tty
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in  // restart if it dies; the new run re-baselines
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.startNettop() }
        }
        queue.sync { (baselined, buffer, sampleRows, procLast) = (false, Data(), [:], [:]) }
        do { try p.run() } catch { close(master); return }
        try? tty.close()  // the children have their own copies
        nettop = p
        // FileHandle.readabilityHandler never fires on a pty master, so read it on a plain thread.
        Thread.detachNewThread { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(master, &bytes, bytes.count)
                if n <= 0 { break }  // EIO once nettop and the wrapper are gone
                let chunk = Data(bytes[0..<n])
                self?.queue.async { self?.consume(chunk) }
            }
            close(master)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: ["\r"])  // tty line endings
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix(",bytes_in") {
                finishSample()  // each sample starts with a header row
            } else if let row = parseNettopRow(Substring(line)) {
                sampleRows[row.pid] = row.traffic
            }
        }
    }

    /// A job step can start, download and exit between two nettop samples (a 3 MB curl takes well under a second),
    /// so parent links are snapshotted 4x a second and remembered after the process is gone.
    private func rememberParents() {
        parents.merge(parentMap()) { old, new in new == 1 ? old : new }  // orphaned to launchd: keep the parent it had
        if parents.count > 20_000 { parents = parentMap() }  // ponytail: forget exited pids eventually; a reused pid could be misattributed until then
    }

    private func finishSample() {
        guard !sampleRows.isEmpty else { return }
        let alive = parentMap()
        for (pid, value) in sampleRows {
            let d = growth(procLast[pid] ?? Traffic(), value)  // a process first seen after the baseline counts from its start
            procLast[pid] = value
            if baselined, d.total > 0, let org = owner(of: pid, parents: parents, roots: roots) {
                pendingRunners[org, default: Traffic()] += d
            }
        }
        procLast = procLast.filter { sampleRows[$0.key] != nil || alive[$0.key] != nil }
        baselined = true  // the first sample only records where every existing process already was
        sampleRows = [:]
    }

    // ponytail: rewrites the whole history as JSON once a minute (~9k rows per connection per year); move to SQLite if that ever gets slow
    func save() {
        var rows = hours.flatMap { connection, byHour in byHour.map { UsageRow(hour: $0.key, connection: connection, traffic: $0.value, source: nil) } }
        for (org, byConnection) in runnerHours {
            for (connection, byHour) in byConnection {
                rows += byHour.map { UsageRow(hour: $0.key, connection: connection, traffic: $0.value, source: org) }
            }
        }
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file, options: .atomic) }
        savedAt = Date()
    }
}
