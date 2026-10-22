import SwiftUI

struct Proc {
    let pid: Int, ppid: Int, cpu: Double, rss: Int64, etime: String, cmd: String
}

struct Job: Identifiable {
    let id = UUID()
    var runner = ""
    let name: String
    var result = ""
    let start: Date?
    var end: Date? = nil
    var url: URL? = nil  // the run on GitHub
    var duration: TimeInterval? { start.flatMap { s in end.map { $0.timeIntervalSince(s) } } }
}

enum RunnerState: String {
    case idle, busy, stopped
    var tone: Tone { self == .idle ? .ok : self == .busy ? .info : .danger }
    var color: Color { tone.text }
    var title: String { rawValue.capitalized }
    var icon: String { self == .idle ? "server.rack" : self == .busy ? "hammer.fill" : "power" }
}

struct Runner: Identifiable {
    var id: String { dir }
    let dir: String, org: String, name: String, url: String, plist: String, label: String
    var version = "?"
    var state = RunnerState.stopped
    var service: (pid: Int?, status: String)?  // nil = launchd service not loaded
    var listener: Proc?
    var jobLoad: (cpu: Double, rss: Int64, count: Int)?
    var cpu = 0.0, rss: Int64 = 0, procCount = 0  // whole service process tree: runner + any running job
    var current: Job?
    var lastEvent: (date: Date, msg: String)?
    var jobs: [Job] = []
    var diagActivity: Date?
    var simulatorIncluded = false  // booted Simulators were counted in cpu/rss
    var logDir: String { "\(home)/Library/Logs/\(label)" }
}

struct Sample: Identifiable {
    let date: Date, cpu: Double, rss: Double  // cpu as % of the whole Mac
    var id: Date { date }
}

struct StorageItem: Identifiable {
    let name: String, bytes: Int64
    var id: String { name }
}

let storageKinds: [(name: String, color: Color)] = [
    ("Checkouts & builds", .infoMark), ("Tool cache", .purpleMark), ("Actions cache", .tealMark),
    ("Old versions & leftovers", .warnMark), ("Runner install", .neutralMark), ("Logs", .dangerMark),
]

struct SystemStats {
    var cpu = 0.0, load = [0.0, 0.0, 0.0], memUsed = 0.0, swapUsed = 0.0, diskTotal = 0.0, diskFree = 0.0
    var memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var power = "", battery: Int?, uptime: TimeInterval = 0
    var thermal = ProcessInfo.ThermalState.nominal
}

enum LogKind: String, CaseIterable, Identifiable {
    case service = "Service", runner = "Diagnostics", worker = "Last job"
    var id: String { rawValue }
}
