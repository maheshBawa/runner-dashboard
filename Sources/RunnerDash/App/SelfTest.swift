import Foundation
import Sparkle

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
    let base = NSTemporaryDirectory() + "runner-dashboard-dirs-\(getpid())"
    for d in ["home/actions-runner-a", "home/Library/LaunchAgents", "elsewhere/r1"] { try? fm.createDirectory(atPath: "\(base)/\(d)", withIntermediateDirectories: true) }
    let agents = base + "/home/Library/LaunchAgents"
    NSDictionary(dictionary: ["WorkingDirectory": base + "/elsewhere/r1/"]).write(toFile: agents + "/actions.runner.x.r1.plist", atomically: true)
    NSDictionary(dictionary: ["WorkingDirectory": base + "/home/actions-runner-a"]).write(toFile: agents + "/actions.runner.y.a.plist", atomically: true)
    NSDictionary(dictionary: ["WorkingDirectory": base + "/not-a-runner"]).write(toFile: agents + "/com.example.other.plist", atomically: true)
    let listeners = [Proc(pid: 1, ppid: 1, cpu: 0, rss: 0, etime: "", cmd: base + "/other dir/r2/bin.2.300.0/Runner.Listener run"),
                     Proc(pid: 2, ppid: 1, cpu: 0, rss: 0, etime: "", cmd: base + "/home/actions-runner-a/bin/Runner.Listener run --startuptype service")]
    let dirs = runnerDirs(listeners, in: base + "/home")
    precondition(dirs == [base + "/elsewhere/r1", base + "/home/actions-runner-a", base + "/other dir/r2"], "\(dirs)")
    try? fm.removeItem(atPath: base)
    let pasted = "# Create the runner and start the configuration experience\n$ ./config.sh --url https://github.com/acme-labs/ --token AABBCC123\n"
    precondition(parseConfigCommand(pasted).map { $0.url == "https://github.com/acme-labs" && $0.token == "AABBCC123" } == true)
    precondition(parseConfigCommand("./config.sh --url https://github.com/acme-labs") == nil)
    precondition(newRunnerDir(for: "https://github.com/Acme/My.Repo").hasPrefix(home + "/actions-runner-my.repo"))
    precondition(newRunnerDir(for: "https://github.com/..").hasPrefix(home + "/actions-runner-runner"))
    precondition(configError("Http response code: NotFound from 'POST https://api.github.com/actions/runner-registration'").hasPrefix("GitHub didn't accept"))
    precondition(configError("a\n\n b \nc\nd\n") == "b\nc\nd")
    precondition(parseLabels(" ios, xcode-16  fastlane,") == ["ios", "xcode-16", "fastlane"] && parseLabels(" ").isEmpty)
    // Sparkle compares CFBundleVersion: a local 1.1.0 built after the 1.1.1 release must still be offered 1.1.1.
    if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, let appVersion {
        precondition(build.hasPrefix(appVersion + "."), "CFBundleVersion \(build) must start with the version")
    }
    precondition(SUStandardVersionComparator().compareVersion("1.1.0.20261022161139", toVersion: "1.1.1.20261022110814") == .orderedAscending)
    print("ok")
}
