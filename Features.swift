// Runner Dashboard features that act on their own or extend the runner screen: settings, notifications, keeping the
// Mac awake, pausing on battery, cleaning up when the disk fills, runner update notices, removing old runner versions,
// GitHub run links, build-time trends and 30-day CPU/RAM history.
import AppKit
import Charts
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Preferences

enum Pref {
    static let notifyFailed = "notifyJobFailed"
    static let notifySucceeded = "notifyJobSucceeded"
    static let notifyOffline = "notifyRunnerOffline"
    static let notifyDisk = "notifyDiskLow"
    static let diskAlertGB = "diskAlertGB"
    static let dataCapGB = "monthlyDataCapGB"
    static let keepAwake = "keepAwakeDuringJobs"
    static let autoClean = "autoCleanWhenDiskLow"
    static let autoCleanGB = "autoCleanBelowGB"
    static let autoCleanDerivedData = "autoCleanDerivedData"
    static let batteryPause = "pauseOnLowBattery"
    static let batteryPercent = "pauseBelowBatteryPercent"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyFailed: true, notifySucceeded: false, notifyOffline: true, notifyDisk: true, diskAlertGB: 15,
            dataCapGB: 0, keepAwake: true, autoClean: false, autoCleanGB: 15, autoCleanDerivedData: false,
            batteryPause: false, batteryPercent: 30,
        ])
    }
}

// MARK: - Helpers

/// Leftovers a runner no longer uses: the previous bin.x/externals.x after a self-update, the install archive and the
/// update staging folder. Whatever `bin`/`externals` currently point to is never included.
func oldVersionPaths(_ dir: String) -> [String] {
    let names = list(dir)
    var out: [String] = []
    for link in ["bin", "externals"] {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(dir)/\(link)") else { continue }  // a plain folder: nothing to compare with
        let current = (target as NSString).lastPathComponent
        out += names.filter { $0.hasPrefix(link + ".") && $0 != current }.map { "\(dir)/\($0)" }
    }
    out += names.filter { $0.hasSuffix(".tar.gz") || $0.hasSuffix(".zip") }.map { "\(dir)/\($0)" }
    if FileManager.default.fileExists(atPath: dir + "/_work/_update") { out.append(dir + "/_work/_update") }
    return out
}

/// "2.337.0" is older than "2.338.0".
func isOlder(_ version: String, than other: String) -> Bool {
    let a = version.split(separator: ".").compactMap { Int($0) }, b = other.split(separator: ".").compactMap { Int($0) }
    return !a.isEmpty && a.lexicographicallyPrecedes(b)
}

func capture(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

let workerStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

private var runLinkCache: [String: URL?] = [:]  // worker log -> run URL; only used from collect(), which never overlaps itself

/// GitHub run links from the runner's worker logs (one log per job, named after its start time).
func runLinks(_ dir: String) -> [(start: Date, url: URL)] {
    list(dir + "/_diag").filter { $0.hasPrefix("Worker_") }.compactMap { name in
        guard let start = workerStamp.date(from: String(name.dropFirst(7).prefix(15))) else { return nil }  // Worker_20261015-104935-utc.log
        let path = dir + "/_diag/" + name
        if let cached = runLinkCache[path] { return cached.map { (start, $0) } }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 400_000)) ?? Data(), as: UTF8.self)  // the job message is near the top
        func value(_ key: String) -> String? { capture("\"k\": \"\(key)\",\\s*\"v\": \"([^\"]+)\"", in: head) }
        let url = value("repository").flatMap { repo in
            value("run_id").flatMap { URL(string: "\(value("server_url") ?? "https://github.com")/\(repo)/actions/runs/\($0)") }
        }
        if url != nil || Date().timeIntervalSince(start) > 600 { runLinkCache[path] = url }  // a brand-new log may not have it yet
        return url.map { (start, $0) }
    }
}

/// The run link for a job that started at `start`: the worker log that began closest to it.
func runLink(_ links: [(start: Date, url: URL)], for start: Date?) -> URL? {
    guard let start else { return nil }
    return links.filter { $0.start.timeIntervalSince(start) > -10 && $0.start.timeIntervalSince(start) < 120 }
        .min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }?.url
}

func appSupportFile(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runner Dashboard")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

// MARK: - 30-day resource history

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

// MARK: - Automation

/// Everything that happens without a click: notifications, keeping the Mac awake, pausing on battery, cleaning up when
/// the disk fills, and checking for runner updates. Store calls `update` after every refresh (every 5 s).
final class Automation: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var keepingAwake = false
    @Published private(set) var latestRunnerVersion: String?
    @Published private(set) var latestAppVersion: String?
    @Published private(set) var appUpdateStep: AppUpdateStep?
    @Published private(set) var appUpdateError: String?
    @Published private(set) var pausedForBattery = Set(UserDefaults.standard.stringArray(forKey: "pausedForBattery") ?? []) {
        didSet { UserDefaults.standard.set(Array(pausedForBattery), forKey: "pausedForBattery") }
    }
    var expectedStops: [String: Date] = [:]  // runner -> when the user stopped/restarted it; no "went offline" alert for those
    var openRunner: ((String) -> Void)?      // set by the window so a notification click can show a runner
    private var seenJobs: Set<String>?
    private var stoppedStreak: [String: Int] = [:]
    private var wasRunning: Set<String> = []
    private var diskAlerted = false
    private var assertion: IOPMAssertionID = 0
    private var lastAutoClean = Date.distantPast
    private var lastUpdateCheck = Date.distantPast
    private var lastAppUpdateCheck = Date.distantPast

    override init() {
        super.init()
        Pref.registerDefaults()
        guard Bundle.main.bundleIdentifier != nil else { return }  // notifications need a real app bundle (not a bare test binary)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(_ store: Store) {
        let prefs = UserDefaults.standard
        notifyJobs(store.runners, prefs)
        notifyOffline(store.runners, prefs)
        checkDisk(store, prefs)
        checkDataCap(store, prefs)
        keepAwake(prefs.bool(forKey: Pref.keepAwake) && store.busyCount > 0)
        batteryPause(store, prefs)
        autoClean(store, prefs)
        if Date().timeIntervalSince(lastUpdateCheck) > 6 * 3600 { checkForRunnerUpdate() }
        if Date().timeIntervalSince(lastAppUpdateCheck) > 3600 { checkForAppUpdate() }
    }

    private func notifyJobs(_ runners: [Runner], _ prefs: UserDefaults) {
        var keys = Set<String>()
        for r in runners {
            for j in r.jobs.prefix(20) {
                let key = "\(r.dir)|\(j.end?.timeIntervalSince1970 ?? 0)|\(j.name)"
                keys.insert(key)
                guard let seen = seenJobs, !seen.contains(key) else { continue }  // the first pass only learns what's already there
                let ok = j.result == "Succeeded", cancelled = j.result.hasPrefix("Cancel")
                guard !cancelled, prefs.bool(forKey: ok ? Pref.notifySucceeded : Pref.notifyFailed) else { continue }
                notify("\(ok ? "✅" : "❌") \(r.org): \(j.name) \(j.result.lowercased())",
                       "Took \(duration(j.duration)). " + (j.url != nil ? "Click to open the run on GitHub." : "Click to open the runner."),
                       runner: r.dir, url: j.url)
            }
        }
        seenJobs = (seenJobs ?? []).union(keys)
    }

    /// Alerts when a runner that was up stays down for ~15 s without anyone stopping it (a quick self-update restart doesn't count).
    private func notifyOffline(_ runners: [Runner], _ prefs: UserDefaults) {
        for r in runners {
            guard r.state == .stopped else {
                wasRunning.insert(r.dir)
                stoppedStreak[r.dir] = 0
                continue
            }
            stoppedStreak[r.dir, default: 0] += 1
            guard wasRunning.contains(r.dir), stoppedStreak[r.dir]! >= 3 else { continue }
            wasRunning.remove(r.dir)
            let expected = expectedStops[r.dir].map { Date().timeIntervalSince($0) < 120 } ?? false
            expectedStops[r.dir] = nil
            if !expected, !pausedForBattery.contains(r.dir), prefs.bool(forKey: Pref.notifyOffline) {
                notify("⚠️ \(r.org) went offline", "Its runner service stopped and nobody stopped it from here. It won't pick up jobs until it's started again.", runner: r.dir)
            }
        }
    }

    private func checkDisk(_ store: Store, _ prefs: UserDefaults) {
        guard store.sys.diskTotal > 0 else { return }
        let free = store.sys.diskFree / 1e9, limit = Double(prefs.integer(forKey: Pref.diskAlertGB))
        if free < limit {
            if !diskAlerted, prefs.bool(forKey: Pref.notifyDisk) {
                notify("💾 Disk almost full", String(format: "%.1f GB free. Builds fail when the disk fills up; clean workspaces or DerivedData from the dashboard.", free))
            }
            diskAlerted = true
        } else if free > limit + 5 {
            diskAlerted = false
        }
    }

    private func checkDataCap(_ store: Store, _ prefs: UserDefaults) {
        let cap = Double(prefs.integer(forKey: Pref.dataCapGB))
        guard cap > 0 else { return }
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let used = Double(store.net.total(since: month).total) / 1e9
        guard let level = [100, 80].first(where: { used >= cap * Double($0) / 100 }) else { return }
        let key = "\(month.formatted(.iso8601.year().month()))@\(level)"
        var sent = Set(prefs.stringArray(forKey: "dataCapAlerts") ?? [])
        guard !sent.contains(key) else { return }
        sent.insert(key)
        prefs.set(Array(sent), forKey: "dataCapAlerts")
        notify(level == 100 ? "📶 Monthly data cap reached" : "📶 80% of this month's data used", String(format: "%.1f of %.0f GB used this month on this Mac.", used, cap))
    }

    private func keepAwake(_ on: Bool) {
        guard on != keepingAwake else { return }
        if on {
            keepingAwake = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "Runner Dashboard: a CI job is running" as CFString, &assertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            keepingAwake = false
        }
    }

    /// Stops idle runners when the battery runs low and starts them again on power. A running job is allowed to finish.
    private func batteryPause(_ store: Store, _ prefs: UserDefaults) {
        let onBattery = store.sys.power.contains("Battery")
        let enabled = prefs.bool(forKey: Pref.batteryPause)
        if enabled, onBattery, (store.sys.battery ?? 100) < prefs.integer(forKey: Pref.batteryPercent) {
            let idle = store.runners.filter { $0.state == .idle && !pausedForBattery.contains($0.dir) }
            guard !idle.isEmpty else { return }
            for r in idle {
                pausedForBattery.insert(r.dir)
                store.stop(r)
            }
            notify("🔋 Runners paused", "\(idle.map(\.org).joined(separator: ", ")) stopped at \(store.sys.battery ?? 0)% battery. They start again when you plug in.")
        } else if (!onBattery || !enabled), !pausedForBattery.isEmpty {
            let paused = store.runners.filter { pausedForBattery.contains($0.dir) }
            for r in paused where r.state == .stopped { store.start(r) }
            pausedForBattery = []
            if !paused.isEmpty { notify("🔌 Runners resumed", "\(paused.map(\.org).joined(separator: ", ")) started again.") }
        }
    }

    /// When free space drops below the limit, cleans the workspaces of runners that aren't running a job (at most hourly).
    private func autoClean(_ store: Store, _ prefs: UserDefaults) {
        guard prefs.bool(forKey: Pref.autoClean), store.sys.diskTotal > 0,
              store.sys.diskFree / 1e9 < Double(prefs.integer(forKey: Pref.autoCleanGB)),
              Date().timeIntervalSince(lastAutoClean) > 3600 else { return }
        lastAutoClean = Date()
        let targets = store.runners.filter { $0.state != .busy && (store.cleanableBytes($0) ?? 0) > 50_000_000 }
        var freed = targets.reduce(Int64(0)) { $0 + (store.cleanableBytes($1) ?? 0) }
        var cleaned = targets.map(\.org)
        for r in targets { store.cleanWorkspace(r) }
        if prefs.bool(forKey: Pref.autoCleanDerivedData), store.busyCount == 0, let dd = store.derivedDataBytes, dd > 0 {
            store.clearDerivedData()
            freed += dd
            cleaned.append("Xcode DerivedData")
        }
        if !cleaned.isEmpty { notify("🧹 Freed about \(fileSize(freed))", "Disk space was low, so this was cleaned: \(cleaned.joined(separator: ", ")).") }
    }

    private func checkForRunnerUpdate() {
        lastUpdateCheck = Date()
        URLSession.shared.dataTask(with: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!) { data, _, _ in
            guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = json["tag_name"] as? String else { return }
            DispatchQueue.main.async { self.latestRunnerVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
        }.resume()
    }

    func notify(_ title: String, _ body: String, runner: String? = nil, url: URL? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["runner": runner ?? "", "url": url?.absoluteString ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let link = info["url"] as? String, let url = URL(string: link), !link.isEmpty {
                NSWorkspace.shared.open(url)
            } else if let dir = info["runner"] as? String, !dir.isEmpty {
                self.openRunner?(dir)
            }
            done()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/// Posts one sample notification so you can see how alerts look. Reports whether notifications are allowed.
func postTestNotification(_ done: @escaping (Bool) -> Void) {
    guard Bundle.main.bundleIdentifier != nil else { return done(false) }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return done(false) }
        let content = UNMutableNotificationContent()
        content.title = "Runner Dashboard"
        content.body = "Notifications are working. You'll hear from me when a job fails, a runner goes offline or the disk fills up."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)) { error in done(error == nil) }
    }
}

// MARK: - Settings

struct OpenAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Open at login", isOn: $on)
            .help("Usage is only recorded while this app is running. Turn this on so tracking survives restarts.")
            .onChange(of: on) { _, value in
                guard value != (SMAppService.mainApp.status == .enabled) else { return }
                try? value ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                on = SMAppService.mainApp.status == .enabled  // reflect what macOS actually accepted
            }
    }
}

struct SettingsView: View {
    @AppStorage(Pref.notifyFailed) private var notifyFailed = true
    @AppStorage(Pref.notifySucceeded) private var notifySucceeded = false
    @AppStorage(Pref.notifyOffline) private var notifyOffline = true
    @AppStorage(Pref.notifyDisk) private var notifyDisk = true
    @AppStorage(Pref.diskAlertGB) private var diskAlertGB = 15
    @AppStorage(Pref.dataCapGB) private var dataCapGB = 0
    @AppStorage(Pref.keepAwake) private var keepAwake = true
    @AppStorage(Pref.autoClean) private var autoClean = false
    @AppStorage(Pref.autoCleanGB) private var autoCleanGB = 15
    @AppStorage(Pref.autoCleanDerivedData) private var autoCleanDerivedData = false
    @AppStorage(Pref.batteryPause) private var batteryPause = false
    @AppStorage(Pref.batteryPercent) private var batteryPercent = 30
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Notify me when") {
                Toggle("A job fails", isOn: $notifyFailed)
                Toggle("A job succeeds", isOn: $notifySucceeded)
                Toggle("A runner goes offline on its own", isOn: $notifyOffline)
                Toggle("Free disk space is low", isOn: $notifyDisk)
                Stepper("Below \(diskAlertGB) GB free", value: $diskAlertGB, in: 5...200, step: 5).disabled(!notifyDisk).padding(.leading, 20)
                LabeledContent("Monthly data cap") {
                    HStack {
                        TextField("", value: $dataCapGB, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("GB")
                    }
                }
                .help("Alerts at 80% and 100% of this much data per month on this Mac. 0 turns it off.")
            }
            Section {
                Toggle("Keep the Mac awake while a job is running", isOn: $keepAwake)
            } header: {
                Text("Sleep")
            } footer: {
                Text("Prevents idle sleep only. Closing the lid on battery still sleeps the Mac and takes the runners offline.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Clean idle runners' workspaces when disk space is low", isOn: $autoClean)
                Stepper("Below \(autoCleanGB) GB free", value: $autoCleanGB, in: 5...200, step: 5).disabled(!autoClean).padding(.leading, 20)
                Toggle("Also clear Xcode DerivedData", isOn: $autoCleanDerivedData).disabled(!autoClean).padding(.leading, 20)
            } header: {
                Text("Automatic cleanup")
            } footer: {
                Text("Runs at most once an hour and never touches a runner that's running a job. The tool cache is kept.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause runners on low battery", isOn: $batteryPause)
                Stepper("Below \(batteryPercent)%", value: $batteryPercent, in: 10...90, step: 5).disabled(!batteryPause).padding(.leading, 20)
            } header: {
                Text("Battery")
            } footer: {
                Text("Idle runners are stopped and start again when you plug in. A job that's already running is allowed to finish.").foregroundStyle(.secondary)
            }
            Section("General") {
                OpenAtLoginToggle()
                LabeledContent("Notifications") {
                    Button("Send test notification") {
                        postTestNotification { ok in DispatchQueue.main.async { testResult = ok ? "Sent" : "Turned off in System Settings › Notifications" } }
                    }
                }
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Menu bar icon") {
                    Button("Preview build animation") { requestMenuIconPreview() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
    }
}

// MARK: - App updates

let appRepo = "maheshBawa/runner-dashboard"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
/// Apps opened from Finder don't get the shell's PATH, so look where Homebrew installs gh.
let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

enum AppUpdateStep: String, CaseIterable {
    case downloading = "Downloading", checking = "Checking", installing = "Installing", restarting = "Restarting"
    var fraction: Double { Double(Self.allCases.firstIndex(of: self)! + 1) / Double(Self.allCases.count) }
}

// ponytail: goes through the user's gh login because the repo is private (and gh downloads aren't quarantined).
// Other Macs need gh signed in too; use a public repo or Sparkle if this ships beyond your own machines.
extension Automation {
    var appUpdateAvailable: Bool {
        guard let appVersion, let latestAppVersion else { return false }
        return isOlder(appVersion, than: latestAppVersion)
    }

    func checkForAppUpdate() {
        lastAppUpdateCheck = Date()
        guard let gh = ghPath, appVersion != nil else { return }
        DispatchQueue.global().async {
            let r = run(gh, ["release", "view", "-R", appRepo, "--json", "tagName", "-q", ".tagName"])
            guard r.ok, let tag = r.out.split(separator: "\n").first, tag.hasPrefix("v") else { return }
            DispatchQueue.main.async { self.latestAppVersion = String(tag.dropFirst()) }
        }
    }

    /// Downloads the latest release, checks it, swaps it in for this copy of the app and restarts into it.
    func installAppUpdate() {
        guard let gh = ghPath, let version = latestAppVersion, appUpdateStep == nil else { return }
        let app = Bundle.main.bundleURL
        appUpdateError = nil
        appUpdateStep = .downloading
        DispatchQueue.global().async {
            let fm = FileManager.default
            func step(_ s: AppUpdateStep) { DispatchQueue.main.async { self.appUpdateStep = s } }
            func fail(_ message: String) { DispatchQueue.main.async { self.appUpdateStep = nil; self.appUpdateError = message } }
            // On the app's own volume, so the swap below is a rename.
            guard let tmp = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true) else { return fail("Couldn't make a folder for the download.") }
            defer { try? fm.removeItem(at: tmp) }
            let download = run(gh, ["release", "download", "v\(version)", "-R", appRepo, "-p", "*.zip", "-D", tmp.path])
            guard download.ok, let zip = list(tmp.path).first(where: { $0.hasSuffix(".zip") }) else { return fail("Download failed. \(download.out)") }
            step(.checking)
            let new = tmp.appendingPathComponent("Runner Dashboard.app")
            guard run("/usr/bin/ditto", ["-x", "-k", tmp.appendingPathComponent(zip).path, tmp.path]).ok,
                  run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]).ok,
                  Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier,
                  run(new.appendingPathComponent("Contents/MacOS/RunnerDash").path, ["--selftest"]).ok
            else { return fail("The download didn't pass its checks, so nothing was changed.") }
            step(.installing)
            do { _ = try fm.replaceItemAt(app, withItemAt: new) } catch { return fail("Couldn't replace the app: \(error.localizedDescription)") }
            step(.restarting)
            // A detached shell waits for this process to quit, then opens the new copy.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
            try? relaunch.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        }
    }
}

/// Shown in the menu panel and the window when a newer Runner Dashboard release is out, and while it installs.
struct AppUpdateBanner: View {
    @EnvironmentObject var automation: Automation
    var body: some View {
        if let latest = automation.latestAppVersion, automation.appUpdateAvailable {
            VStack(alignment: .leading, spacing: 8) {
                if let step = automation.appUpdateStep {
                    ProgressView(value: step.fraction) {
                        Text("\(step.rawValue) v\(latest)…").font(.callout.weight(.medium))
                    }
                    .tint(.infoFill)
                    .animation(.easeInOut, value: step)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.infoMark)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Update available").font(.callout.weight(.semibold))
                            Text("v\(latest) · you have v\(appVersion ?? "?")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update now") { automation.installAppUpdate() }.buttonStyle(.borderedProminent).tint(.infoFill)
                    }
                    if let error = automation.appUpdateError {
                        Text(error).font(.caption).foregroundStyle(Color.dangerText).lineLimit(3)
                    }
                }
            }
            .card(padding: 12)
        }
    }
}

// MARK: - Runner screen additions

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

// MARK: - Menu bar icon

/// Menu bar icon in the app icon's style: one blade per runner (up to 4), drawn as a template image so it adapts to
/// light and dark menu bars. Idle: outlined, light on. Busy: solid, with a light sweeping back and forth inside it
/// (`frame` drives the animation). Stopped: faint outline, light off.
func menuBarImage(_ states: [RunnerState], frame: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { rect in
        let blades = states.isEmpty ? [RunnerState.stopped] : Array(states.prefix(4))
        let gap: CGFloat = blades.count > 3 ? 1 : 1.2
        let h = (rect.height - gap * CGFloat(blades.count - 1)) / CGFloat(blades.count)
        for (i, state) in blades.enumerated() {
            let blade = NSRect(x: 1, y: CGFloat(i) * (h + gap), width: rect.width - 2, height: h)
            let outline = NSBezierPath(roundedRect: blade.insetBy(dx: 0.5, dy: 0.5), xRadius: (h - 1) / 2, yRadius: (h - 1) / 2)
            outline.lineWidth = 1
            switch state {
            case .idle:
                NSColor.black.set()
                outline.stroke()
                let d = h - 2.4
                NSBezierPath(ovalIn: NSRect(x: blade.minX + 1.4, y: blade.midY - d / 2, width: d, height: d)).fill()
            case .busy:
                NSColor.black.set()
                NSBezierPath(roundedRect: blade, xRadius: h / 2, yRadius: h / 2).fill()
                // The light is cut out of the solid blade and sweeps back and forth (16 frames per round trip).
                let t = CGFloat(frame % 16), phase = t < 8 ? t / 8 : (16 - t) / 8
                let w = blade.width * 0.32, lh = h * 0.42, travel = blade.width - w - 2.8
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(roundedRect: NSRect(x: blade.minX + 1.4 + travel * phase, y: blade.midY - lh / 2, width: w, height: lh),
                             xRadius: lh / 2, yRadius: lh / 2).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .stopped:
                NSColor.black.withAlphaComponent(0.35).set()
                outline.stroke()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

extension Notification.Name {
    /// Posted (distributed) by `RunnerDash --preview-icon` or the Settings button: animate every blade for 20 s.
    static let previewMenuIcon = Notification.Name("local.runner-dashboard.preview-menu-icon")
}

func requestMenuIconPreview() {
    DistributedNotificationCenter.default().postNotificationName(.previewMenuIcon, object: nil, userInfo: nil, deliverImmediately: true)
}

/// Publishes the current menu bar image, redrawing ~11x a second only while a runner is busy (or a preview runs).
final class MenuBarIcon: ObservableObject {
    @Published private(set) var image = menuBarImage([], frame: 0)
    private var real: [RunnerState] = []
    private var shown: [RunnerState]?
    private var previewUntil = Date.distantPast
    private var frame = 0
    private var timer: Timer?

    init() {
        DistributedNotificationCenter.default().addObserver(forName: .previewMenuIcon, object: nil, queue: .main) { [weak self] _ in self?.preview() }
    }

    func update(_ states: [RunnerState]) {
        real = states
        apply()
    }

    func preview(seconds: TimeInterval = 20) {
        previewUntil = Date().addingTimeInterval(seconds)
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.apply() }
    }

    private func apply() {
        let states = previewUntil > Date() ? (real.isEmpty ? [.busy] : real.map { _ in RunnerState.busy }) : real
        guard states != shown else { return }
        shown = states
        if states.contains(.busy) {
            if timer == nil {
                let t = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                    guard let self, let shown = self.shown else { return }
                    self.frame += 1
                    self.image = menuBarImage(shown, frame: self.frame)
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            frame = 0
        }
        image = menuBarImage(states, frame: frame)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var icon: MenuBarIcon
    var body: some View { Image(nsImage: icon.image) }
}
