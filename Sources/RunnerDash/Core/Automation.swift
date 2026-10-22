import AppKit
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

/// Everything that happens without a click: notifications, keeping the Mac awake, pausing on battery, cleaning up when
/// the disk fills, and checking for runner updates. Store calls `update` after every refresh (every 5 s).
final class Automation: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var keepingAwake = false
    @Published private(set) var latestRunnerVersion: String?
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
