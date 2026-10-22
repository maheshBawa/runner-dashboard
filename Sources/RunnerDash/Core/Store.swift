import SwiftUI

final class Store: ObservableObject {
    let net = NetworkUsage()
    let automation = Automation()
    let updater = AppUpdater()
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
