import Foundation

func fileSize(_ b: Int64?) -> String { b.map { bytes($0, .file) } ?? "…" }
func memSize(_ b: Double) -> String { bytes(Int64(b), .memory) }
func bytes(_ b: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let f = ByteCountFormatter()
    f.countStyle = style
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: b)
}
func pct(_ v: Double) -> String { v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%" }

func duration(_ s: TimeInterval?) -> String {
    guard let s else { return "—" }
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute, .second]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f.string(from: s) ?? "—"
}

func ago(_ d: Date?) -> String {
    guard let d else { return "—" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

func thermalName(_ t: ProcessInfo.ThermalState) -> String {
    switch t {
    case .nominal: return "Normal"
    case .fair: return "Fair"
    case .serious: return "Serious"
    case .critical: return "Critical"
    @unknown default: return "Unknown"
    }
}
