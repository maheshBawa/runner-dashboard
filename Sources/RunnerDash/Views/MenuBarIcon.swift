import AppKit
import SwiftUI

/// Menu bar icon in the app icon's style: one blade per runner (up to 4), drawn as a template image so it adapts to
/// light and dark menu bars. Idle: outlined, light on. Busy: solid, with a light sweeping back and forth inside it
/// (`frame` drives the animation). Stopped: faint outline, light off.
func menuBarImage(_ states: [RunnerState], frame: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { rect in
        let blades = states.isEmpty ? [RunnerState.stopped] : Array(states.prefix(4))
        let gap: CGFloat = blades.count > 3 ? 1 : 1.2
        let h = (rect.height - gap * CGFloat(blades.count - 1)) / CGFloat(blades.count)
        for (i, state) in blades.enumerated() {
            let blade = NSRect(x: 1, y: CGFloat(i) * (h + gap), width: rect.width - 2, height: h)
            let outline = NSBezierPath(roundedRect: blade.insetBy(dx: 0.5, dy: 0.5), xRadius: (h - 1) / 2, yRadius: (h - 1) / 2)
            outline.lineWidth = 1
            switch state {
            case .idle:
                NSColor.black.set()
                outline.stroke()
                let d = h - 2.4
                NSBezierPath(ovalIn: NSRect(x: blade.minX + 1.4, y: blade.midY - d / 2, width: d, height: d)).fill()
            case .busy:
                NSColor.black.set()
                NSBezierPath(roundedRect: blade, xRadius: h / 2, yRadius: h / 2).fill()
                // The light is cut out of the solid blade and sweeps back and forth (16 frames per round trip).
                let t = CGFloat(frame % 16), phase = t < 8 ? t / 8 : (16 - t) / 8
                let w = blade.width * 0.32, lh = h * 0.42, travel = blade.width - w - 2.8
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(roundedRect: NSRect(x: blade.minX + 1.4 + travel * phase, y: blade.midY - lh / 2, width: w, height: lh),
                             xRadius: lh / 2, yRadius: lh / 2).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .stopped:
                NSColor.black.withAlphaComponent(0.35).set()
                outline.stroke()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

extension Notification.Name {
    /// Posted (distributed) by `RunnerDash --preview-icon` or the Settings button: animate every blade for 20 s.
    static let previewMenuIcon = Notification.Name("local.runner-dashboard.preview-menu-icon")
}

func requestMenuIconPreview() {
    DistributedNotificationCenter.default().postNotificationName(.previewMenuIcon, object: nil, userInfo: nil, deliverImmediately: true)
}

/// Publishes the current menu bar image, redrawing ~11x a second only while a runner is busy (or a preview runs).
final class MenuBarIcon: ObservableObject {
    @Published private(set) var image = menuBarImage([], frame: 0)
    private var real: [RunnerState] = []
    private var shown: [RunnerState]?
    private var previewUntil = Date.distantPast
    private var frame = 0
    private var timer: Timer?

    init() {
        DistributedNotificationCenter.default().addObserver(forName: .previewMenuIcon, object: nil, queue: .main) { [weak self] _ in self?.preview() }
    }

    func update(_ states: [RunnerState]) {
        real = states
        apply()
    }

    func preview(seconds: TimeInterval = 20) {
        previewUntil = Date().addingTimeInterval(seconds)
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.apply() }
    }

    private func apply() {
        let states = previewUntil > Date() ? (real.isEmpty ? [.busy] : real.map { _ in RunnerState.busy }) : real
        guard states != shown else { return }
        shown = states
        if states.contains(.busy) {
            if timer == nil {
                let t = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                    guard let self, let shown = self.shown else { return }
                    self.frame += 1
                    self.image = menuBarImage(shown, frame: self.frame)
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            frame = 0
        }
        image = menuBarImage(states, frame: frame)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var icon: MenuBarIcon
    var body: some View { Image(nsImage: icon.image) }
}
