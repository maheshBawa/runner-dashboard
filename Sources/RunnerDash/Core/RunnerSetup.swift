import Foundation

/// The --url and --token from the ./config.sh line on GitHub's "New self-hosted runner" page.
func parseConfigCommand(_ text: String) -> (url: String, token: String)? {
    guard let url = capture("--url\\s+(https://[^\\s'\"]+)", in: text), let token = capture("--token\\s+([A-Za-z0-9]+)", in: text) else { return nil }
    return (url.hasSuffix("/") ? String(url.dropLast()) : url, token)
}

/// config.sh's default name (the short hostname), numbered when this Mac already has a runner for the same org or repo:
/// GitHub wants unique names there, and svc.sh names the launch agent actions.runner.<org>.<name>.
func defaultRunnerName(for url: String, existing: [Runner]) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    gethostname(&buf, buf.count)
    let host = String(cString: buf).split(separator: ".").first.map(String.init) ?? "mac"
    let taken = Set(existing.filter { $0.url == url }.map(\.name))
    var name = host, n = 2
    while taken.contains(name) { name = "\(host)-\(n)"; n += 1 }
    return name
}

/// A new ~/actions-runner-<org or repo> folder, numbered if taken.
func newRunnerDir(for url: String) -> String {
    let s = (url.split(separator: "/").last ?? "").lowercased().filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    let base = "\(home)/actions-runner-\(s.allSatisfy { $0 == "." } ? "runner" : s)"
    var dir = base, n = 2
    while FileManager.default.fileExists(atPath: dir) { dir = "\(base)-\(n)"; n += 1 }
    return dir
}

/// GitHub's setup steps for a new runner, then svc.sh install + start: downloads the latest runner into a new
/// ~/actions-runner-* folder, registers it and starts it as a launch agent. Returns an error message, or nil.
func createRunner(url: String, token: String, name: String, step: (String) -> Void) -> String? {
    step("Finding the latest runner…")
    let release = run("/usr/bin/curl", ["-fsSL", "https://api.github.com/repos/actions/runner/releases/latest"])
    guard let version = capture("\"tag_name\":\\s*\"v([^\"]+)\"", in: release.out) else {
        return "Couldn't reach GitHub to find the latest runner. \(release.out)"
    }
    let dir = newRunnerDir(for: url), fm = FileManager.default
    // Until the runner is registered, a failure leaves nothing behind.
    func fail(_ message: String) -> String { try? fm.removeItem(atPath: dir); return message }
    do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch { return error.localizedDescription }
    step("Downloading runner \(version)…")
    let tarball = dir + "/runner.tar.gz"
    var r = run("/usr/bin/curl", ["-fsSL", "-o", tarball, "https://github.com/actions/runner/releases/download/v\(version)/actions-runner-osx-arm64-\(version).tar.gz"])
    guard r.ok else { return fail("Couldn't download the runner. \(r.out)") }
    r = run("/usr/bin/tar", ["xzf", tarball, "-C", dir])
    try? fm.removeItem(atPath: tarball)
    guard r.ok else { return fail("Couldn't unpack the runner. \(r.out)") }
    step("Registering with GitHub…")
    // Through an interactive login shell, as if run in Terminal: config.sh saves its PATH and tool variables (JAVA_HOME,
    // ANDROID_HOME, …) for jobs to use, and the app's own environment has neither Homebrew nor those.
    r = run(loginShell, ["-ilc", "exec \"$0\" \"$@\"", dir + "/config.sh", "--unattended", "--url", url, "--token", token, "--name", name], in: dir)
    guard r.ok else { return fail(configError(r.out)) }
    step("Starting…")
    for cmd in ["install", "start"] {
        r = run(dir + "/svc.sh", [cmd], in: dir)
        guard r.ok else { return "\(name) is registered, but its service didn't \(cmd): \(r.out)" }
    }
    return nil
}

/// The user's shell when it takes -ilc like zsh and bash do; zsh otherwise.
private var loginShell: String {
    let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? ""
    return shell.hasSuffix("/zsh") || shell.hasSuffix("/bash") ? shell : "/bin/zsh"
}

/// config.sh's failure in words: a fix for the token and name problems, the last lines of output for anything else.
func configError(_ out: String) -> String {
    if out.contains("runner-registration") || out.contains("404") {
        return "GitHub didn't accept the token. Tokens expire an hour after the page loads: reload GitHub's New runner page and paste the command again."
    }
    if out.contains("same name") { return "A runner with this name is already registered there. Choose another name." }
    return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3).joined(separator: "\n")
}
