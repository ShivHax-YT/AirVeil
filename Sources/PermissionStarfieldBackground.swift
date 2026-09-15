import SwiftUI
import AppKit

/// Quiet depth behind the permission glass. Particles are deterministic and
/// decorative; inactive or reduced-motion views contain no animation timeline.
struct PermissionStarfieldBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var windowIsActive = false
    @State private var origin = Date()
    private let isVisible: Bool

    init(isVisible: Bool = true) { self.isVisible = isVisible }

    private var animates: Bool {
        isVisible && appeared && windowIsActive && !reduceMotion
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.012), Color(white: 0.003)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { tick in
                    stars(time: max(0, tick.date.timeIntervalSince(origin)), moving: true)
                }
            } else {
                stars(time: 0, moving: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(PermissionStarfieldVisibility { windowIsActive = $0 })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }

    private func stars(time: TimeInterval, moving: Bool) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            for star in Self.particles {
                let point = CGPoint(x: star.x * size.width, y: star.y * size.height)
                let pulse = moving ? sin(time * star.speed + star.phase) : sin(star.phase)
                let opacity = star.opacity * (0.82 + 0.18 * pulse)
                let core = CGRect(x: point.x - star.diameter / 2, y: point.y - star.diameter / 2,
                                  width: star.diameter, height: star.diameter)
                context.fill(Path(ellipseIn: core.insetBy(dx: -1.25, dy: -1.25)),
                             with: .color(.white.opacity(opacity * 0.065)))
                context.fill(Path(ellipseIn: core), with: .color(.white.opacity(opacity)))
            }
            if moving { Self.drawMeteor(context: &context, size: size, time: time) }
        }
        .blur(radius: 0.7)
    }

    private struct Star {
        let x: Double
        let y: Double
        let diameter: Double
        let opacity: Double
        let phase: Double
        let speed: Double
    }

    private static let particles: [Star] = (0..<44).map { index in
        Star(x: 0.035 + noise(index, 1) * 0.93,
             y: 0.025 + noise(index, 2) * 0.95,
             diameter: 0.7 + noise(index, 3) * 1.0,
             opacity: 0.19 + noise(index, 4) * 0.32,
             phase: noise(index, 5) * .pi * 2,
             speed: 0.32 + noise(index, 6) * 0.46)
    }

    /// One faint streak, under 34 points long, with a long quiet interval.
    private static func drawMeteor(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let interval = 18.0
        let cycle = Int(time / interval)
        let elapsed = time.truncatingRemainder(dividingBy: interval) - 7
        let duration = 2.1
        guard elapsed >= 0, elapsed < duration else { return }
        let progress = elapsed / duration
        let opacity = sin(progress * .pi) * 0.40
        let travel = 65 + noise(cycle, 8) * 35
        let length = 20 + noise(cycle, 9) * 13
        let start = CGPoint(x: (0.12 + noise(cycle, 10) * 0.70) * size.width,
                            y: (0.08 + noise(cycle, 11) * 0.72) * size.height)
        let head = CGPoint(x: start.x + travel * progress, y: start.y + travel * progress * 0.46)
        let tail = CGPoint(x: head.x - length, y: head.y - length * 0.46)
        var path = Path()
        path.move(to: tail); path.addLine(to: head)
        context.stroke(path, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(opacity)]),
            startPoint: tail, endPoint: head), style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
    }

    private static func noise(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index * 73 + salt * 199 + 17) * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}

/// AppKit-hosted SwiftUI has no owning SwiftUI Scene to supply scenePhase.
/// Read the actual host window instead, using notifications rather than a timer.
private struct PermissionStarfieldVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = changed
        view.scheduleRefresh()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopObserving()
        view.changed = nil
    }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var lastValue: Bool?
        private var refreshScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            let center = NotificationCenter.default
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.willCloseNotification] {
                    center.addObserver(self, selector: #selector(activityChanged), name: name, object: window)
                }
                for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    center.addObserver(self, selector: #selector(activityChanged), name: name, object: nil)
                }
            }
            scheduleRefresh()
        }

        override func viewDidHide() { super.viewDidHide(); scheduleRefresh() }
        override func viewDidUnhide() { super.viewDidUnhide(); scheduleRefresh() }

        @objc private func activityChanged(_ notification: Notification) { scheduleRefresh() }

        func stopObserving() { NotificationCenter.default.removeObserver(self) }

        func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            // Window close notifications precede the actual visibility change.
            // Defer one main-queue turn and avoid updating SwiftUI during layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                let visible = self.window.map {
                    $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                } ?? false
                let active = visible && !self.isHiddenOrHasHiddenAncestor && NSApp?.isActive == true
                guard self.lastValue != active else { return }
                self.lastValue = active
                self.changed?(active)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
