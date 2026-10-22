// Runner Dashboard: menu bar + window dashboard for self-hosted GitHub Actions runners in ~/actions-runner*.
// Build: ./build.sh   Self-check: ~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest
import AppKit
import Charts
import CoreLocation
import CoreWLAN
import ServiceManagement
import SwiftUI
import SystemConfiguration

let home = FileManager.default.homeDirectoryForCurrentUser.path
let derivedData = home + "/Library/Developer/Xcode/DerivedData"

// MARK: - Shell & files

@discardableResult
func run(_ exe: String, _ args: [String]) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (error.localizedDescription, false) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}

func read(_ path: String) -> String {
    FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

func tail(_ path: String, lines: Int = 300) -> String {
    guard let h = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? h.close() }
    let end = h.seekToEndOfFile()
    h.seek(toFileOffset: end > 256_000 ? end - 256_000 : 0)
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
}

func du(_ path: String) -> Int64 {
    (Int64(run("/usr/bin/du", ["-sk", path]).out.prefix { $0.isNumber }) ?? 0) * 1024
}

func remove(_ paths: [String]) -> (out: String, ok: Bool) {
    for p in paths {
        do { try FileManager.default.removeItem(atPath: p) } catch { return (error.localizedDescription, false) }
    }
    return ("", true)
}

func list(_ dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
}

/// First number in the text matched by a regex, e.g. number("Pages active:\\s+\\d+", vmStat).
func number(_ pattern: String, in text: String) -> Double {
    guard let r = text.range(of: pattern, options: .regularExpression) else { return 0 }
    return Double(text[r].filter { $0.isNumber || $0 == "." }) ?? 0
}

// MARK: - Model

struct Proc {
    let pid: Int, ppid: Int, cpu: Double, rss: Int64, etime: String, cmd: String
}

struct Job: Identifiable {
    let id = UUID()
    var runner = ""
    let name: String
    var result = ""
    let start: Date?
    var end: Date? = nil
    var url: URL? = nil  // the run on GitHub
    var duration: TimeInterval? { start.flatMap { s in end.map { $0.timeIntervalSince(s) } } }
}

enum RunnerState: String {
    case idle, busy, stopped
    var tone: Tone { self == .idle ? .ok : self == .busy ? .info : .danger }
    var color: Color { tone.text }
    var title: String { rawValue.capitalized }
    var icon: String { self == .idle ? "server.rack" : self == .busy ? "hammer.fill" : "power" }
}

struct Runner: Identifiable {
    var id: String { dir }
    let dir: String, org: String, name: String, url: String, plist: String, label: String
    var version = "?"
    var state = RunnerState.stopped
    var service: (pid: Int?, status: String)?  // nil = launchd service not loaded
    var listener: Proc?
    var jobLoad: (cpu: Double, rss: Int64, count: Int)?
    var cpu = 0.0, rss: Int64 = 0, procCount = 0  // whole service process tree: runner + any running job
    var current: Job?
    var lastEvent: (date: Date, msg: String)?
    var jobs: [Job] = []
    var diagActivity: Date?
    var simulatorIncluded = false  // booted Simulators were counted in cpu/rss
    var logDir: String { "\(home)/Library/Logs/\(label)" }
}

struct Sample: Identifiable {
    let date: Date, cpu: Double, rss: Double  // cpu as % of the whole Mac
    var id: Date { date }
}

struct StorageItem: Identifiable {
    let name: String, bytes: Int64
    var id: String { name }
}

let storageKinds: [(name: String, color: Color)] = [
    ("Checkouts & builds", .infoMark), ("Tool cache", .purpleMark), ("Actions cache", .tealMark),
    ("Old versions & leftovers", .warnMark), ("Runner install", .neutralMark), ("Logs", .dangerMark),
]

struct SystemStats {
    var cpu = 0.0, load = [0.0, 0.0, 0.0], memUsed = 0.0, swapUsed = 0.0, diskTotal = 0.0, diskFree = 0.0
    var memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var power = "", battery: Int?, uptime: TimeInterval = 0
    var thermal = ProcessInfo.ThermalState.nominal
}

enum LogKind: String, CaseIterable, Identifiable {
    case service = "Service", runner = "Diagnostics", worker = "Last job"
    var id: String { rawValue }
}

// MARK: - Collection

let utcStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Runner service stdout.log -> (finished jobs newest-first, unfinished job, last event).
func parseEvents(_ text: String) -> (jobs: [Job], current: Job?, last: (date: Date, msg: String)?) {
    var jobs: [Job] = [], current: Job?, last: (date: Date, msg: String)?
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)  // lines look like "2026-10-14 09:08:17Z: Running job: build"
        guard line.count > 22, line.dropFirst(19).hasPrefix("Z: "), let t = utcStamp.date(from: String(line.prefix(19))) else { continue }
        let msg = String(line.dropFirst(22))
        last = (t, msg)
        if msg.hasPrefix("Running job: ") {
            current = Job(name: String(msg.dropFirst(13)), start: t)
        } else if msg.hasPrefix("Job "), let r = msg.range(of: " completed with result: ", options: .backwards) {
            let name = String(msg[msg.index(msg.startIndex, offsetBy: 4)..<r.lowerBound])
            jobs.append(Job(name: name, result: String(msg[r.upperBound...]), start: current?.name == name ? current?.start : nil, end: t))
            current = nil
        }
    }
    return (jobs.reversed(), current, last)
}

typealias ServiceEvents = (jobs: [Job], current: Job?, last: (date: Date, msg: String)?)

private var serviceLogCache: [String: (stamp: String, events: ServiceEvents, version: String?)] = [:]  // only used from collect()

/// A runner's parsed service log and version, re-parsed only when the file changes (it changes on job events, not every 5 s).
func serviceLog(_ path: String) -> (events: ServiceEvents, version: String?) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let stamp = "\(attrs?[.modificationDate] ?? "")|\(attrs?[.size] ?? "")"
    if let cached = serviceLogCache[path], cached.stamp == stamp { return (cached.events, cached.version) }
    let text = read(path)
    let version = text.range(of: "Current runner version: '", options: .backwards).map { String(text[$0.upperBound...].prefix { $0 != "'" }) }
    let events = parseEvents(text)
    serviceLogCache[path] = (stamp, events, version)
    return (events, version)
}

/// ps elapsed time "[[dd-]hh:]mm:ss" -> seconds.
func seconds(etime: String) -> TimeInterval {
    let dayParts = etime.split(separator: "-")
    let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
    let hms = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
    return days * 86400 + hms.reduce(0) { $0 * 60 + $1 }
}

func processes() -> [Proc] {
    run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,etime=,command="]).out.split(separator: "\n").compactMap { line in
        let f = line.split(maxSplits: 5, whereSeparator: { $0 == " " })
        guard f.count == 6, let pid = Int(f[0]), let ppid = Int(f[1]), let cpu = Double(f[2]), let rss = Int64(f[3]) else { return nil }
        return Proc(pid: pid, ppid: ppid, cpu: cpu, rss: rss * 1024, etime: String(f[4]), cmd: f[5].trimmingCharacters(in: .whitespaces))
    }
}

/// The job process. Matches both <dir>/bin/ and the versioned <dir>/bin.2.x.y/ the listener actually spawns from.
func worker(_ dir: String, in procs: [Proc]) -> Proc? {
    procs.first { $0.cmd.hasPrefix(dir + "/bin") && $0.cmd.contains("Runner.Worker") }
}

/// Disk usage of a runner folder by what it's for. "Checkouts & builds" is what Clean deletes; "Old versions &
/// leftovers" is what Remove old versions deletes.
func storageBreakdown(_ dir: String) -> [StorageItem] {
    let old = Set(oldVersionPaths(dir))
    var bytes: [String: Int64] = [:]
    for name in list(dir + "/_work") {
        let path = dir + "/_work/" + name
        let kind = old.contains(path) ? "Old versions & leftovers"
            : ["_tool": "Tool cache", "_actions": "Actions cache"][name] ?? (name.hasPrefix("_") && name != "_temp" ? "Runner install" : "Checkouts & builds")
        bytes[kind, default: 0] += du(path)
    }
    for name in list(dir) where name != "_work" {
        let path = dir + "/" + name
        bytes[old.contains(path) ? "Old versions & leftovers" : name == "_diag" ? "Logs" : "Runner install", default: 0] += du(path)
    }
    return storageKinds.map { StorageItem(name: $0.name, bytes: bytes[$0.name] ?? 0) }
}

func collect() -> ([Runner], SystemStats) {
    let procs = processes()
    var kids: [Int: [Proc]] = [:]
    for p in procs { kids[p.ppid, default: []].append(p) }
    let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    func tree(_ root: Proc) -> [Proc] {
        var out = [root], stack = [root.pid]
        while let pid = stack.popLast() {
            for c in kids[pid] ?? [] { out.append(c); stack.append(c.pid) }
        }
        return out
    }
    var services: [String: (pid: Int?, status: String)] = [:]
    for line in run("/bin/launchctl", ["list"]).out.split(separator: "\n").dropFirst() {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false)
        if f.count == 3 { services[String(f[2])] = (Int(f[0]), String(f[1])) }
    }

    var runners: [Runner] = list(home).filter { $0.hasPrefix("actions-runner") }.sorted().compactMap { name in
        let dir = home + "/" + name
        guard var data = FileManager.default.contents(atPath: dir + "/.runner") else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }  // .runner is written with a BOM
        guard let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let url = cfg["gitHubUrl"] as? String ?? ""
        let plist = read(dir + "/.service").trimmingCharacters(in: .whitespacesAndNewlines)
        var r = Runner(dir: dir, org: url.split(separator: "/").last.map(String.init) ?? "?", name: cfg["agentName"] as? String ?? "?",
                       url: url, plist: plist, label: ((plist as NSString).lastPathComponent as NSString).deletingPathExtension)
        r.service = services[r.label]
        r.listener = procs.first { $0.cmd.hasPrefix(dir + "/bin") && $0.cmd.contains("Runner.Listener") }
        if let w = worker(dir, in: procs) {
            let t = tree(w)
            r.jobLoad = (t.reduce(0) { $0 + $1.cpu }, t.reduce(0) { $0 + $1.rss }, t.count)
        }
        if let root = r.service?.pid.flatMap({ byPid[$0] }) ?? r.listener {
            let t = tree(root)
            (r.cpu, r.rss, r.procCount) = (t.reduce(0) { $0 + $1.cpu }, t.reduce(0) { $0 + $1.rss }, t.count)
        }
        r.state = r.listener == nil ? .stopped : r.jobLoad != nil ? .busy : .idle
        let (events, version) = serviceLog(r.logDir + "/stdout.log")
        let links = runLinks(dir)
        r.jobs = events.jobs.map { var j = $0; j.runner = r.org; j.url = runLink(links, for: j.start); return j }
        r.current = r.state == .busy ? events.current : nil
        let currentLink = runLink(links, for: r.current?.start)
        r.current?.url = currentLink
        r.lastEvent = events.last
        r.version = version ?? "?"
        r.diagActivity = list(dir + "/_diag").filter { $0.hasSuffix(".log") }
            .compactMap { (try? FileManager.default.attributesOfItem(atPath: dir + "/_diag/" + $0))?[.modificationDate] as? Date }.max()
        return r
    }

    // Booted Simulators run under launchd, not under the job, so credit them to the busy runner when there's only one.
    let busy = runners.indices.filter { runners[$0].state == .busy }
    let sims = procs.filter { $0.cmd.contains("/sbin/launchd_sim") }.flatMap(tree)
    if busy.count == 1, !sims.isEmpty {
        let i = busy[0], cpu = sims.reduce(0) { $0 + $1.cpu }, rss = sims.reduce(0) { $0 + $1.rss }
        (runners[i].cpu, runners[i].rss, runners[i].procCount) = (runners[i].cpu + cpu, runners[i].rss + rss, runners[i].procCount + sims.count)
        if let l = runners[i].jobLoad { runners[i].jobLoad = (l.cpu + cpu, l.rss + rss, l.count + sims.count) }
        runners[i].simulatorIncluded = true
    }

    var s = SystemStats()
    let vm = run("/usr/bin/vm_stat", []).out
    let page = number("page size of \\d+", in: vm)
    s.memUsed = page * ["Pages active", "Pages wired down", "Pages occupied by compressor"].reduce(0) { $0 + number($1 + ":\\s+\\d+", in: vm) }
    s.swapUsed = number("used = [\\d.]+M", in: run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).out) * 1_048_576
    s.cpu = procs.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount)
    getloadavg(&s.load, 3)
    let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
    s.diskTotal = Double(disk?.volumeTotalCapacity ?? 0)
    s.diskFree = Double(disk?.volumeAvailableCapacityForImportantUsage ?? 0)
    let batt = run("/usr/bin/pmset", ["-g", "batt"]).out
    s.power = batt.range(of: "'[^']+'", options: .regularExpression).map { batt[$0].trimmingCharacters(in: ["'"]) } ?? ""
    s.battery = batt.contains("%") ? Int(number("\\d+%", in: batt)) : nil
    s.thermal = ProcessInfo.processInfo.thermalState
    var boot = timeval(), size = MemoryLayout<timeval>.size  // wall-clock since boot (systemUptime skips sleep)
    if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { s.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec) }
    return (runners, s)
}

func readLog(_ r: Runner?, _ kind: LogKind) -> String {
    guard let r else { return "" }
    if kind == .service {
        let err = tail(r.logDir + "/stderr.log", lines: 100)
        return tail(r.logDir + "/stdout.log") + (err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n--- stderr ---\n" + err)
    }
    // Diag file names embed a UTC timestamp, so the lexicographic max is the newest.
    let latest = list(r.dir + "/_diag").filter { $0.hasPrefix(kind == .runner ? "Runner_" : "Worker_") }.max()
    return latest.map { "== \($0) ==\n" + tail(r.dir + "/_diag/" + $0) } ?? "(no log yet)"
}

// MARK: - Store

final class Store: ObservableObject {
    let net = NetworkUsage()
    let automation = Automation()
    let resources = ResourceHistory()
    let menuBarIcon = MenuBarIcon()
    @Published var runners: [Runner] = []
    @Published var sys = SystemStats()
    @Published var history: [String: [Sample]] = [:]      // per runner dir: last 15 min at 5 s
    @Published var storage: [String: [StorageItem]] = [:]  // per runner dir: re-measured every 5 min and after actions
    @Published var derivedDataBytes: Int64?
    @Published var working: Set<String> = []              // runner dirs / paths with an action in flight
    @Published var error: String?
    @Published var path: [Route] = []                      // window navigation
    @Published var logRunner = "" { didSet { if logRunner != oldValue { reloadLog() } } }
    @Published var logKind = LogKind.service { didSet { if logKind != oldValue { reloadLog() } } }
    @Published var logText = ""
    private var refreshing = false
    private var sizedAt = Date.distantPast
    private var timer: Timer?

    var busyCount: Int { runners.filter { $0.state == .busy }.count }

    init() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let (logRunner, logKind) = (self.logRunner, self.logKind)
        DispatchQueue.global(qos: .utility).async {
            let (runners, sys) = collect()
            let log = readLog(runners.first { $0.dir == logRunner }, logKind)
            DispatchQueue.main.async {
                let now = Date(), cores = Double(ProcessInfo.processInfo.activeProcessorCount)
                var history = self.history
                for r in runners {
                    history[r.dir] = Array(((history[r.dir] ?? []) + [Sample(date: now, cpu: r.cpu / cores, rss: Double(r.rss))]).suffix(180))
                }
                self.history = history
                self.runners = runners
                self.sys = sys
                self.net.setRunnerRoots(Dictionary(runners.compactMap { r in r.listener.map { ($0.pid, r.org) } }, uniquingKeysWith: { a, _ in a }))
                self.resources.record(runners)
                self.automation.update(self)
                self.menuBarIcon.update(runners.map(\.state))
                self.refreshing = false
                if (logRunner, logKind) == (self.logRunner, self.logKind) { self.logText = log }
                if Date().timeIntervalSince(self.sizedAt) > 300 { self.measureStorage() }
            }
        }
    }

    func reloadLog() {
        let (r, kind) = (runners.first { $0.dir == logRunner }, logKind)
        DispatchQueue.global(qos: .userInitiated).async {
            let log = readLog(r, kind)
            DispatchQueue.main.async { if r?.dir == self.logRunner && kind == self.logKind { self.logText = log } }
        }
    }

    private func measureStorage() {
        sizedAt = Date()
        let dirs = runners.map(\.dir)
        DispatchQueue.global(qos: .background).async {
            for d in dirs {
                let items = storageBreakdown(d)
                DispatchQueue.main.async { self.storage[d] = items }
            }
            let bytes = du(derivedData)
            DispatchQueue.main.async { self.derivedDataBytes = bytes }
        }
    }

    private func perform(_ key: String, _ work: @escaping () -> (out: String, ok: Bool)) {
        working.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.working.remove(key)
                if !result.ok { self.error = result.out.isEmpty ? "Action failed." : result.out }
                self.sizedAt = .distantPast
                self.refresh()
            }
        }
    }

    // Same launchd calls as the runner's own svc.sh start/stop; restart uses kickstart -k.
    func start(_ r: Runner) {
        perform(r.dir) { r.service == nil ? run("/bin/launchctl", ["load", "-w", r.plist]) : run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(r.label)"]) }
    }

    func stop(_ r: Runner) {
        automation.expectedStops[r.dir] = Date()
        perform(r.dir) { run("/bin/launchctl", ["unload", r.plist]) }
    }

    func restart(_ r: Runner) {
        automation.expectedStops[r.dir] = Date()
        perform(r.dir) { r.service == nil ? run("/bin/launchctl", ["load", "-w", r.plist]) : run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(r.label)"]) }
    }

    /// Deletes repo checkouts/build outputs and _temp in _work. Keeps _tool (toolchain cache), _actions and runner bookkeeping.
    func cleanWorkspace(_ r: Runner) {
        perform(r.dir) {
            if worker(r.dir, in: processes()) != nil { return ("\(r.org) just picked up a job, so its workspace was not cleaned.", false) }
            let work = r.dir + "/_work"
            return remove(list(work).filter { !$0.hasPrefix("_") }.map { work + "/" + $0 } + list(work + "/_temp").map { work + "/_temp/" + $0 })
        }
    }

    func clearDerivedData() {
        perform(derivedData) {
            if processes().contains(where: { $0.cmd.contains("Runner.Worker") }) { return ("A runner is running a job, so DerivedData was not cleared.", false) }
            return remove(list(derivedData).map { derivedData + "/" + $0 })
        }
    }

    /// Deletes runner versions and downloads the runner no longer uses (see oldVersionPaths). Never while it's busy or updating itself.
    func removeOldVersions(_ r: Runner) {
        perform(r.dir) {
            let procs = processes()
            if worker(r.dir, in: procs) != nil || procs.contains(where: { $0.cmd.contains(r.dir + "/_work/_update") }) {
                return ("\(r.org) is running a job or updating itself, so nothing was removed. Try again when it's idle.", false)
            }
            return remove(oldVersionPaths(r.dir))
        }
    }

    func oldVersionBytes(_ r: Runner) -> Int64? {
        storage[r.dir]?.first { $0.name == "Old versions & leftovers" }?.bytes
    }

    func cleanableBytes(_ r: Runner) -> Int64? {
        storage[r.dir]?.first { $0.name == storageKinds[0].name }?.bytes
    }
}

// MARK: - Formatting

func fileSize(_ b: Int64?) -> String { b.map { bytes($0, .file) } ?? "…" }
func memSize(_ b: Double) -> String { bytes(Int64(b), .memory) }
func bytes(_ b: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let f = ByteCountFormatter()
    f.countStyle = style
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: b)
}
func pct(_ v: Double) -> String { v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%" }

func duration(_ s: TimeInterval?) -> String {
    guard let s else { return "—" }
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute, .second]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f.string(from: s) ?? "—"
}

func ago(_ d: Date?) -> String {
    guard let d else { return "—" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

func thermalName(_ t: ProcessInfo.ThermalState) -> String {
    switch t {
    case .nominal: return "Normal"
    case .fair: return "Fair"
    case .serious: return "Serious"
    case .critical: return "Critical"
    @unknown default: return "Unknown"
    }
}

// MARK: - Colors

/// The app's colors by role, each checked by the self-test against the app's light and dark surfaces:
/// - `text`: colored words, which sit on cards: at least 4.5:1 (WCAG AA for text).
/// - `mark`: icons, rings, bars and chart lines: vivid, at least 3:1 (WCAG AA for graphics).
/// - `fill` and `tileTop`: solid badges and tiles: white text on `fill` is at least 4.5:1, white glyphs on the
///   `tileTop`→`fill` gradient at least 3:1.
/// macOS's own green/orange/cyan/yellow are only 1.2–3.2:1 as text on light backgrounds, so words never use them.
enum Tone: CaseIterable {
    case ok, info, danger, warn, purple, teal, neutral
    // Tailwind CSS shades.
    var hex: (textLight: UInt32, textDark: UInt32, markLight: UInt32, markDark: UInt32, fill: UInt32, tileTop: UInt32) {
        switch self {
        case .ok: return (0x15803D, 0x4ADE80, 0x16A34A, 0x4ADE80, 0x15803D, 0x16A34A)
        case .info: return (0x2563EB, 0x93C5FD, 0x3B82F6, 0x60A5FA, 0x2563EB, 0x3B82F6)
        case .danger: return (0xDC2626, 0xFCA5A5, 0xEF4444, 0xF87171, 0xDC2626, 0xEF4444)
        case .warn: return (0xC2410C, 0xFBBF24, 0xEA580C, 0xFBBF24, 0xC2410C, 0xEA580C)
        case .purple: return (0x9333EA, 0xD8B4FE, 0xA855F7, 0xC084FC, 0x9333EA, 0xA855F7)
        case .teal: return (0x0F766E, 0x2DD4BF, 0x0D9488, 0x2DD4BF, 0x0F766E, 0x0D9488)
        case .neutral: return (0x52525B, 0xD4D4D8, 0x71717A, 0xA1A1AA, 0x52525B, 0x71717A)
        }
    }
    var text: Color { adaptive(hex.textLight, hex.textDark) }
    var mark: Color { adaptive(hex.markLight, hex.markDark) }
    var fill: Color { Color(nsColor: NSColor(hex: hex.fill)) }
    var tileTop: Color { Color(nsColor: NSColor(hex: hex.tileTop)) }

    private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        let (l, d) = (NSColor(hex: light), NSColor(hex: dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let okText = Tone.ok.text, infoText = Tone.info.text, dangerText = Tone.danger.text
    static let warnText = Tone.warn.text, purpleText = Tone.purple.text, tealText = Tone.teal.text, neutralText = Tone.neutral.text
    static let okMark = Tone.ok.mark, infoMark = Tone.info.mark, dangerMark = Tone.danger.mark
    static let warnMark = Tone.warn.mark, purpleMark = Tone.purple.mark, tealMark = Tone.teal.mark, neutralMark = Tone.neutral.mark
    static let okFill = Tone.ok.fill, infoFill = Tone.info.fill, dangerFill = Tone.danger.fill, warnFill = Tone.warn.fill
    /// Chart series, in order.
    static let series: [Color] = [.infoMark, .warnMark, .okMark, .purpleMark, .tealMark, .dangerMark]
}

/// A solid colored tile with a white glyph, like the icons in System Settings.
struct ToneBadge: View {
    let icon: String, tone: Tone
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tone.tileTop, tone.fill], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: tone.fill.opacity(0.3), radius: 6, y: 2)
    }
}

/// WCAG contrast ratio between two sRGB colors (1...21).
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
        let v = Double((hex >> shift) & 0xFF) / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    func luminance(_ hex: UInt32) -> Double { 0.2126 * channel(hex, 16) + 0.7152 * channel(hex, 8) + 0.0722 * channel(hex, 0) }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

func levelColor(_ fraction: Double, _ base: Color) -> Color { fraction > 0.9 ? .dangerMark : fraction > 0.75 ? .warnMark : base }

let explanations = [
    "CPU": "CPU used by this runner's whole process tree (service, listener and any running job, including Xcode's build service) as a share of the Mac's total CPU. Booted iOS Simulators are added while this is the only busy runner. Live covers the time since the dashboard opened; 7 days shows hourly averages.",
    "Memory": "RAM (resident memory) used by this runner's whole process tree, including any running job.",
    "Storage": "Disk space used by this runner's folder, split by purpose. Clean deletes “Checkouts & builds”; Remove old versions deletes “Old versions & leftovers” (previous runner versions, the installer and update downloads). The tool cache is kept. Re-measured every 5 minutes.",
    "Build times": "How long each kind of job took on this runner, from successful runs only (failed runs stop early and would skew it). “Last vs average” compares the most recent run with the average of the runs shown.",
    "Service": "The launchd service (LaunchAgent) that keeps this runner alive and starts it at login. “loaded · pid” means launchd is running it; “not loaded” means it was stopped and won't come back until you press Start.",
    "Listener": "The Runner.Listener process that stays connected to GitHub and waits for jobs: its uptime, CPU and memory. Near 0% CPU is normal while idle.",
    "Job load": "CPU and memory used by the job running right now (Runner.Worker plus everything it launched, and booted Simulators when this is the only busy runner). Each core counts as 100%, so it can exceed 100%. Shows — when idle.",
    "Diag activity": "When the runner last wrote to its diagnostic log in _diag. It renews its GitHub token about every 50 minutes, so under ~1 hr means it's alive and talking to GitHub.",
    "Last event": "The latest line in the runner's service log: listening, job started/finished, or a connection error. Orange means an error; if Diag activity is more recent, the runner has recovered.",
    "Jobs 24h / total": "Jobs finished in the last 24 hours / all jobs recorded in this runner's service log.",
    "Success rate": "Share of recorded jobs that finished as Succeeded. Failed, Cancelled and Abandoned jobs count against it.",
    "Avg duration": "Average time from job start to finish across all recorded jobs.",
    "Network": "Data this runner's own processes (the listener and every job step: git, CocoaPods/SPM, uploads) sent and received, measured per process with macOS's nettop. Downloads that system services make on a job's behalf, like Xcode fetching simulator runtimes, aren't included.",
    "By runner": "Each runner's traffic is measured per process (the listener and every job step) and recorded under the connection in use at the time. “Everything else” is the rest of the Mac: other apps, plus downloads system services make on a job's behalf. Runner tracking started on Oct 16, 2026; earlier days only have whole-Mac totals.",
    "Data usage": "Bytes downloaded and uploaded through each network connection, recorded every 5 seconds while this app is running (turn on Open at login so nothing is missed). Includes local-network traffic such as AirPlay or file sharing. VPN traffic is counted once, on the connection that carries it.",
]

// MARK: - Building blocks

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
            if r.state == .stopped {
                Button { store.start(r) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(.okFill)
            } else {
                Button { confirm = .stop } label: { Label("Stop", systemImage: "stop.fill") }
            }
            Button { if r.state == .busy { confirm = .restart } else { store.restart(r) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
            Button { confirm = .clean } label: { Label("Clean…", systemImage: "trash") }
                .disabled(r.state == .busy)
                .help(r.state == .busy ? "Not available while a job is running" : "Delete checkouts and build outputs in _work")
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

// MARK: - Overview

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
                    Button {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Notifications, keep awake, automatic cleanup, battery")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(store.runners) { RunnerCard(runner: $0) }
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
        .confirmationDialog("Clear Xcode DerivedData?", isPresented: $confirmDerived) {
            Button("Delete \(fileSize(store.derivedDataBytes))", role: .destructive) { store.clearDerivedData() }
        } message: {
            Text("Deletes everything in ~/Library/Developer/Xcode/DerivedData. It's shared by all runners and your own Xcode, so the next build of each project will be a full (slower) build.")
        }
    }
}

// MARK: - Runner detail

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

// MARK: - Network usage

enum Route: Hashable {
    case runner(String), network
}

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

// MARK: - Menu bar

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
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "gearshape").font(.body.weight(.medium)) }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            VStack(spacing: 6) {
                ForEach(store.runners) { r in
                    MenuRunnerRow(runner: r, open: { open([.runner(r.dir)]) }, confirmStop: confirmStop)
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
                    if r.state == .stopped { Button("Start") { store.start(r) } }
                    else { Button("Stop…") { if confirmStop(r) { store.stop(r) } }.disabled(r.state == .busy) }
                    Button("Restart") { store.restart(r) }.disabled(r.state == .busy)
                    if r.state == .busy { Text("Busy: stop or restart from the dashboard") }
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

// MARK: - App

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

func selfTest() {
    let (jobs, current, last) = parseEvents("""
        √ Connected to GitHub
        2026-10-14 09:08:17Z: Running job: ios / build
        2026-10-14 09:13:39Z: Job ios / build completed with result: Succeeded
        2026-10-14 09:13:43Z: Running job: ios / submit
        """)
    precondition(jobs.count == 1 && jobs[0].name == "ios / build" && jobs[0].result == "Succeeded" && jobs[0].duration == 322, "\(jobs)")
    precondition(current?.name == "ios / submit" && last?.msg == "Running job: ios / submit")
    precondition(seconds(etime: "01-02:12:29") == 94349 && seconds(etime: "05:07") == 307)
    precondition(delta(Traffic(rx: 100, tx: 50), Traffic(rx: 150, tx: 50)) == Traffic(rx: 50, tx: 0))
    precondition(delta(Traffic(rx: 100, tx: 50), Traffic(rx: 30, tx: 10)) == Traffic(rx: 30, tx: 10))  // counters reset
    let hour = Int(Calendar.current.dateInterval(of: .hour, for: Date())!.start.timeIntervalSince1970)
    let days = buckets([hour: Traffic(rx: 5, tx: 1), hour - 86400 * 40: Traffic(rx: 9, tx: 9)], .daily)
    precondition(parseNettopRow("Runner.Listener.2377,1234,567,").map { $0.pid == 2377 && $0.traffic == Traffic(rx: 1234, tx: 567) } == true)
    precondition(parseNettopRow(",bytes_in,bytes_out,") == nil)
    precondition(owner(of: 30, parents: [30: 20, 20: 10, 10: 1], roots: [10: "HushChat"]) == "HushChat")
    precondition(owner(of: 30, parents: [30: 20, 20: 1], roots: [10: "HushChat"]) == nil)
    precondition(growth(Traffic(rx: 10, tx: 10), Traffic(rx: 5, tx: 12)) == Traffic(rx: 0, tx: 2))
    precondition(days.count == 30 && days.last!.traffic == Traffic(rx: 5, tx: 1) && days.reduce(0) { $0 + $1.traffic.total } == 6)
    precondition(isOlder("2.337.0", than: "2.338.0") && !isOlder("2.338.0", than: "2.338.0") && isOlder("2.40.0", than: "2.338.0"))  // numeric, not string order
    precondition(capture("\"k\": \"run_id\",\\s*\"v\": \"([^\"]+)\"", in: "\"k\": \"run_id\",\n   \"v\": \"38722952374\"") == "38722952374")
    let fixture = NSTemporaryDirectory() + "runner-dashboard-selftest-\(getpid())"
    let fm = FileManager.default
    for d in ["bin.2.1.0", "bin.2.0.0", "externals", "_work/_update"] { try? fm.createDirectory(atPath: "\(fixture)/\(d)", withIntermediateDirectories: true) }
    try? fm.createSymbolicLink(atPath: fixture + "/bin", withDestinationPath: fixture + "/bin.2.1.0")
    fm.createFile(atPath: fixture + "/actions-runner-osx-arm64-2.0.0.tar.gz", contents: Data())
    precondition(Set(oldVersionPaths(fixture)) == [fixture + "/bin.2.0.0", fixture + "/actions-runner-osx-arm64-2.0.0.tar.gz", fixture + "/_work/_update"], "\(oldVersionPaths(fixture))")
    try? fm.removeItem(atPath: fixture)
    let (cards, darks) = ([0xFFFFFF] as [UInt32], [0x1E1E1E, 0x2C2C2C, 0x3A3A3A] as [UInt32])
    for tone in Tone.allCases {
        let h = tone.hex
        precondition(cards.allSatisfy { contrast(h.textLight, $0) >= 4.5 } && darks.allSatisfy { contrast(h.textDark, $0) >= 4.5 }, "\(tone) text")
        precondition(cards.allSatisfy { contrast(h.markLight, $0) >= 3 } && darks.allSatisfy { contrast(h.markDark, $0) >= 3 }, "\(tone) mark")
        precondition(contrast(h.fill, 0xFFFFFF) >= 4.5 && contrast(h.tileTop, 0xFFFFFF) >= 3, "\(tone) fill")
    }
    print("ok")
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
