import Foundation

/// A runner folder that Find Runners turned up, and where it found it.
struct FoundRunner: Identifiable {
    enum Source: String { case running = "Running", service = "Service", disk = "On disk" }
    let dir: String, org: String, source: Source
    var id: String { dir }
}

/// Folders of running listeners, whether started with run.sh or as a service.
func listenerDirs(_ procs: [Proc]) -> [String] {
    procs.compactMap { p in
        p.cmd.range(of: "/bin[^/ ]*/Runner\\.Listener", options: .regularExpression).map { String(p.cmd[..<$0.lowerBound]) }
    }
}

/// Folders of runners installed as launch agents: svc.sh records the folder as the plist's WorkingDirectory.
func launchAgentDirs(in agents: String = home + "/Library/LaunchAgents") -> [String] {
    list(agents).filter { $0.hasPrefix("actions.runner.") && $0.hasSuffix(".plist") }.compactMap {
        NSDictionary(contentsOfFile: agents + "/" + $0)?["WorkingDirectory"] as? String
    }
}

/// Walks `root` up to `depth` levels down for runner folders (ones with a .runner file). It skips hidden folders, app
/// bundles, Library and dependency or build folders, the paths in `skip`, and a runner's own insides. `visiting` gets
/// each top-level folder as the walk enters it.
func walkForRunners(_ root: String, depth: Int, skip: Set<String> = [], found: (String) -> Void, visiting: (String) -> Void = { _ in }) {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
    // The enumerator hands back symlink-resolved URLs (/private/var/… for /var/…): report paths as spelled under root.
    // realpath, because resolvingSymlinksInPath strips /private again.
    let resolved = realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root
    for case let url as URL in e {
        if Task.isCancelled { return }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let path = url.path.hasPrefix(resolved + "/") ? root + url.path.dropFirst(resolved.count) : url.path
        if skip.contains(path) || skippedFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
        if e.level == 1 { visiting(path) }
        if fm.fileExists(atPath: path + "/.runner") { found(path); e.skipDescendants() }
        else if e.level >= depth { e.skipDescendants() }
    }
}

private let skippedFolders: Set<String> = ["Library", "node_modules", "Pods", "DerivedData", "build", "_work"]

/// Find Runners: running listeners and launch agents first (instant), then a walk of the home folder, /opt, /usr/local
/// and /Users/Shared. The walk skips Desktop, Documents, Downloads and the media folders, where macOS would stop it to
/// ask for permission. Reports each runner once, as soon as it turns up; `searching` says what's being looked at.
func searchRunners(found: (FoundRunner) -> Void, searching: (String) -> Void) {
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
    launchAgentDirs().forEach { report($0, .service) }
    let asksPermission = Set(["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 })
    for (root, depth) in [(home, 4), ("/opt", 3), ("/usr/local", 3), ("/Users/Shared", 3)] {
        searching("Searching " + (root as NSString).abbreviatingWithTildeInPath)
        walkForRunners(root, depth: depth, skip: asksPermission, found: { report($0, .disk) },
                       visiting: { searching("Searching " + ($0 as NSString).abbreviatingWithTildeInPath) })
        if Task.isCancelled { return }
    }
}
