import Foundation

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
