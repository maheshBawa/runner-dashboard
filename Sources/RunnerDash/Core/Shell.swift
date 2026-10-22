import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let derivedData = home + "/Library/Developer/Xcode/DerivedData"

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
