import AppKit
import SwiftUI

/// The app's colors by role, each checked by the self-test against the app's light and dark surfaces:
/// - `text`: colored words, which sit on cards: at least 4.5:1 (WCAG AA for text).
/// - `mark`: icons, rings, bars and chart lines: vivid, at least 3:1 (WCAG AA for graphics).
/// - `fill` and `tileTop`: solid badges and tiles: white text on `fill` is at least 4.5:1, white glyphs on the
///   `tileTop`→`fill` gradient at least 3:1.
/// macOS's own green/orange/cyan/yellow are only 1.2–3.2:1 as text on light backgrounds, so words never use them.
enum Tone: CaseIterable {
    case ok, info, danger, warn, purple, teal, neutral
    // Tailwind CSS shades.
    var hex: (textLight: UInt32, textDark: UInt32, markLight: UInt32, markDark: UInt32, fill: UInt32, tileTop: UInt32) {
        switch self {
        case .ok: return (0x15803D, 0x4ADE80, 0x16A34A, 0x4ADE80, 0x15803D, 0x16A34A)
        case .info: return (0x2563EB, 0x93C5FD, 0x3B82F6, 0x60A5FA, 0x2563EB, 0x3B82F6)
        case .danger: return (0xDC2626, 0xFCA5A5, 0xEF4444, 0xF87171, 0xDC2626, 0xEF4444)
        case .warn: return (0xC2410C, 0xFBBF24, 0xEA580C, 0xFBBF24, 0xC2410C, 0xEA580C)
        case .purple: return (0x9333EA, 0xD8B4FE, 0xA855F7, 0xC084FC, 0x9333EA, 0xA855F7)
        case .teal: return (0x0F766E, 0x2DD4BF, 0x0D9488, 0x2DD4BF, 0x0F766E, 0x0D9488)
        case .neutral: return (0x52525B, 0xD4D4D8, 0x71717A, 0xA1A1AA, 0x52525B, 0x71717A)
        }
    }
    var text: Color { adaptive(hex.textLight, hex.textDark) }
    var mark: Color { adaptive(hex.markLight, hex.markDark) }
    var fill: Color { Color(nsColor: NSColor(hex: hex.fill)) }
    var tileTop: Color { Color(nsColor: NSColor(hex: hex.tileTop)) }

    private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        let (l, d) = (NSColor(hex: light), NSColor(hex: dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let okText = Tone.ok.text, infoText = Tone.info.text, dangerText = Tone.danger.text
    static let warnText = Tone.warn.text, purpleText = Tone.purple.text, tealText = Tone.teal.text, neutralText = Tone.neutral.text
    static let okMark = Tone.ok.mark, infoMark = Tone.info.mark, dangerMark = Tone.danger.mark
    static let warnMark = Tone.warn.mark, purpleMark = Tone.purple.mark, tealMark = Tone.teal.mark, neutralMark = Tone.neutral.mark
    static let okFill = Tone.ok.fill, infoFill = Tone.info.fill, dangerFill = Tone.danger.fill, warnFill = Tone.warn.fill
    /// Chart series, in order.
    static let series: [Color] = [.infoMark, .warnMark, .okMark, .purpleMark, .tealMark, .dangerMark]
}

/// A solid colored tile with a white glyph, like the icons in System Settings.
struct ToneBadge: View {
    let icon: String, tone: Tone
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tone.tileTop, tone.fill], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: tone.fill.opacity(0.3), radius: 6, y: 2)
    }
}

/// WCAG contrast ratio between two sRGB colors (1...21).
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
        let v = Double((hex >> shift) & 0xFF) / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    func luminance(_ hex: UInt32) -> Double { 0.2126 * channel(hex, 16) + 0.7152 * channel(hex, 8) + 0.0722 * channel(hex, 0) }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

func levelColor(_ fraction: Double, _ base: Color) -> Color { fraction > 0.9 ? .dangerMark : fraction > 0.75 ? .warnMark : base }

let explanations = [
    "CPU": "CPU used by this runner's whole process tree (service, listener and any running job, including Xcode's build service) as a share of the Mac's total CPU. Booted iOS Simulators are added while this is the only busy runner. Live covers the time since the dashboard opened; 7 days shows hourly averages.",
    "Memory": "RAM (resident memory) used by this runner's whole process tree, including any running job.",
    "Storage": "Disk space used by this runner's folder, split by purpose. Clean deletes “Checkouts & builds”; Remove old versions deletes “Old versions & leftovers” (previous runner versions, the installer and update downloads). The tool cache is kept. Re-measured every 5 minutes.",
    "Build times": "How long each kind of job took on this runner, from successful runs only (failed runs stop early and would skew it). “Last vs average” compares the most recent run with the average of the runs shown.",
    "Service": "The launchd service (LaunchAgent) that keeps this runner alive and starts it at login. “loaded · pid” means launchd is running it; “not loaded” means it was stopped and won't come back until you press Start.",
    "Listener": "The Runner.Listener process that stays connected to GitHub and waits for jobs: its uptime, CPU and memory. Near 0% CPU is normal while idle.",
    "Job load": "CPU and memory used by the job running right now (Runner.Worker plus everything it launched, and booted Simulators when this is the only busy runner). Each core counts as 100%, so it can exceed 100%. Shows — when idle.",
    "Diag activity": "When the runner last wrote to its diagnostic log in _diag. It renews its GitHub token about every 50 minutes, so under ~1 hr means it's alive and talking to GitHub.",
    "Last event": "The latest line in the runner's service log: listening, job started/finished, or a connection error. Orange means an error; if Diag activity is more recent, the runner has recovered.",
    "Jobs 24h / total": "Jobs finished in the last 24 hours / all jobs recorded in this runner's service log.",
    "Success rate": "Share of recorded jobs that finished as Succeeded. Failed, Cancelled and Abandoned jobs count against it.",
    "Avg duration": "Average time from job start to finish across all recorded jobs.",
    "Network": "Data this runner's own processes (the listener and every job step: git, CocoaPods/SPM, uploads) sent and received, measured per process with macOS's nettop. Downloads that system services make on a job's behalf, like Xcode fetching simulator runtimes, aren't included.",
    "By runner": "Each runner's traffic is measured per process (the listener and every job step) and recorded under the connection in use at the time. “Everything else” is the rest of the Mac: other apps, plus downloads system services make on a job's behalf. Runner tracking started on Oct 16, 2026; earlier days only have whole-Mac totals.",
    "Data usage": "Bytes downloaded and uploaded through each network connection, recorded every 5 seconds while this app is running (turn on Open at login so nothing is missed). Includes local-network traffic such as AirPlay or file sharing. VPN traffic is counted once, on the connection that carries it.",
]
