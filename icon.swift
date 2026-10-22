// Draws the Runner Dashboard app icon (1024×1024 PNG) on Apple's macOS icon grid: an 824-pt continuous-corner squircle
// with a 100-pt margin. Three server blades (one per runner, with status lights) and a heartbeat line for monitoring.
// Custom shapes only: SF Symbols may not be used in app icons. Run by build.sh: icon <out.png>
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

struct Blade: View {
    let light: Color
    var active = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        shape
            .fill(LinearGradient(colors: [.white.opacity(active ? 0.36 : 0.26), .white.opacity(active ? 0.18 : 0.11)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
            .overlay(alignment: .leading) {
                Circle().fill(light)
                    .overlay(Circle().fill(.white.opacity(0.55)).frame(width: 14, height: 14).offset(x: -6, y: -6))
                    .frame(width: 42, height: 42)
                    .shadow(color: light, radius: 16)
                    .shadow(color: light.opacity(0.8), radius: 5)
                    .padding(.leading, 44)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in Capsule().fill(.white.opacity(0.42)).frame(width: 12, height: 50) }
                }
                .padding(.trailing, 48)
            }
            .frame(width: 560, height: 116)
    }
}

struct Pulse: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.30, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.39, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.50, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.58, y: r.midY - r.height * 0.2))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.64, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

struct AppIcon: View {
    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            squircle
                .fill(LinearGradient(colors: [Color(hex: 0x4F46E5), Color(hex: 0x2563EB), Color(hex: 0x0891B2)], startPoint: .top, endPoint: .bottom))
                .overlay(squircle.fill(RadialGradient(colors: [.white.opacity(0.30), .clear], center: UnitPoint(x: 0.28, y: 0.02), startRadius: 0, endRadius: 640)))
                .overlay(squircle.fill(RadialGradient(colors: [Color(hex: 0x22D3EE).opacity(0.35), .clear], center: UnitPoint(x: 0.85, y: 1.0), startRadius: 0, endRadius: 520)))
                .overlay(squircle.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 10)

            VStack(spacing: 30) {
                Blade(light: Color(hex: 0x4ADE80))
                Blade(light: Color(hex: 0x38BDF8), active: true)
                Blade(light: Color(hex: 0x4ADE80))
            }
            .offset(y: -112)

            Pulse()
                .stroke(LinearGradient(colors: [.white.opacity(0.65), .white, Color(hex: 0xA5F3FC)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round))
                .frame(width: 600, height: 160)
                .shadow(color: Color(hex: 0x67E8F9), radius: 18)
                .offset(y: 240)
        }
        .frame(width: 1024, height: 1024)
    }
}

@main
enum Main {
    @MainActor static func main() {
        let renderer = ImageRenderer(content: AppIcon())
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("render failed") }
        try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
