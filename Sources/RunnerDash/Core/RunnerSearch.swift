import Foundation

/// A runner folder that Find Runners turned up, and where it found it.
struct FoundRunner: Identifiable {
    enum Source: String { case running = "Running", service = "Service", disk = "On disk" }
    let dir: String, org: String, source: Source
    var id: String { dir }
}

/// The runner folder in a listener's path or command line: everything before /bin/ or the versioned /bin.2.x.y/.
func runnerFolder(of path: String) -> String? {
    path.range(of: "/bin[^/ ]*/Runner\\.Listener", options: .regularExpression).map { String(path[..<$0.lowerBound]) }
}

/// Folders of running listeners, any user's, whether started with run.sh or as a service.
func listenerDirs(_ procs: [Proc]) -> [String] {
    procs.compactMap { runnerFolder(of: $0.cmd) }
}

/// Folders of runners installed as launch agents: svc.sh records the folder as the plist's WorkingDirectory.
func launchAgentDirs(in agents: String = home + "/Library/LaunchAgents") -> [String] {
    list(agents).filter { $0.hasPrefix("actions.runner.") && $0.hasSuffix(".plist") }.compactMap {
        NSDictionary(contentsOfFile: agents + "/" + $0)?["WorkingDirectory"] as? String
    }
}

/// Walks `root` up to `depth` levels down for runner folders (ones with a .runner file). It skips hidden folders, app
/// bundles, Library and dependency or build folders, the paths in `skip`, and a runner's own insides. `visiting` gets
/// each folder up to 3 levels down as the walk enters it.
func walkForRunners(_ root: String, depth: Int, skip: Set<String> = [], found: (String) -> Void, visiting: (String) -> Void = { _ in }) {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
    // The enumerator hands back symlink-resolved URLs (/private/var/… for /var/…): report paths as spelled under root.
    // realpath, because resolvingSymlinksInPath strips /private again.
    let resolved = realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root
    for case let url as URL in e {
        if Task.isCancelled { return }
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), v.isDirectory == true else { continue }
        let path = url.path.hasPrefix(resolved + "/") ? root + url.path.dropFirst(resolved.count) : url.path
        if skip.contains(path) || skippedFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
        if e.level <= 3, v.isPackage != true { visiting(path) }
        if fm.fileExists(atPath: path + "/.runner") { found(path); e.skipDescendants() }
        else if e.level >= depth { e.skipDescendants() }
    }
}

private let skippedFolders: Set<String> = ["Library", "node_modules", "Pods", "DerivedData", "build", "_work", "Backups.backupdb"]

/// Find Runners, across the whole Mac and every user, as far as this account can read. It reports each runner once,
/// as soon as it turns up, and `searching` says what's being looked at:
/// 1. running listeners (ps shows every user's)
/// 2. launch agents: this user's, other users' where readable, and the system-wide folders
/// 3. Spotlight, which covers every indexed folder, including the ones the walk skips, without permission prompts
/// 4. hard search only: a walk of the whole disk, external volumes included, for what Spotlight misses (unindexed
///    volumes, excluded folders, indexing off). It skips system areas, /System/Volumes/Data (a second path to the same
///    files) and every user's Desktop, Documents, Downloads and media folders, where macOS would stop it to ask for
///    permission.
func searchRunners(hard: Bool, found: (FoundRunner) -> Void, searching: (String) -> Void) {
    var seen = Set<String>()
    func report(_ dir: String, _ source: FoundRunner.Source) {
        // Only a trailing slash is trimmed: standardizingPath would turn /private/tmp/… into /tmp/…, and the folder has to
        // match the listener's own path for its state.
        let dir = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        guard dir.hasPrefix("/"), let cfg = runnerConfig(dir), seen.insert(dir).inserted else { return }
        found(FoundRunner(dir: dir, org: (cfg["gitHubUrl"] as? String ?? "").split(separator: "/").last.map(String.init) ?? "?", source: source))
    }
    searching("Checking running runners")
    listenerDirs(processes()).forEach { report($0, .running) }
    searching("Checking launch agents")
    let homes = list("/Users").map { "/Users/" + $0 }
    for agents in homes.map({ $0 + "/Library/LaunchAgents" }) + ["/Library/LaunchAgents", "/Library/LaunchDaemons"] {
        launchAgentDirs(in: agents).forEach { report($0, .service) }
    }
    searching("Asking Spotlight")
    run("/usr/bin/mdfind", ["kMDItemFSName == 'Runner.Listener'"]).out.split(separator: "\n").forEach {
        if let dir = runnerFolder(of: String($0)) { report(dir, .disk) }
    }
    if !hard || Task.isCancelled { return }
    let asksPermission = homes.flatMap { h in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { h + "/" + $0 } }
    walkForRunners("/", depth: .max, skip: Set(asksPermission + ["/System", "/private", "/dev", "/cores"]), found: { report($0, .disk) },
                   visiting: { searching("Searching " + ($0 as NSString).abbreviatingWithTildeInPath) })
}
