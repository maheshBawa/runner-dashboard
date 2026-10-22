import Foundation

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

/// Runner folders: ~/actions-runner*, plus runners anywhere else that are installed as a launch agent (svc.sh, which
/// records the folder as WorkingDirectory) or running (run.sh, found by the listener's path).
func runnerDirs(_ procs: [Proc], in root: String = home) -> [String] {
    let agents = root + "/Library/LaunchAgents"
    let named = list(root).filter { $0.hasPrefix("actions-runner") }.map { root + "/" + $0 }
    let services = list(agents).filter { $0.hasPrefix("actions.runner.") && $0.hasSuffix(".plist") }.compactMap {
        NSDictionary(contentsOfFile: agents + "/" + $0)?["WorkingDirectory"] as? String
    }
    let running = procs.compactMap { p in
        p.cmd.range(of: "/bin[^/ ]*/Runner\\.Listener", options: .regularExpression).map { String(p.cmd[..<$0.lowerBound]) }
    }
    var seen = Set<String>()
    // Only a trailing slash is trimmed: standardizingPath would turn /private/tmp/… into /tmp/…, and the folder has to
    // match the listener's own path for its state.
    return (named + services + running).filter { $0.hasPrefix("/") }.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        .filter { seen.insert($0).inserted }.sorted()
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

    var runners: [Runner] = runnerDirs(procs).compactMap { dir in
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
