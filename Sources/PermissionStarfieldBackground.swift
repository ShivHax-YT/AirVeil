import SwiftUI
import AppKit

/// Quiet depth behind the permission glass. Particles are deterministic and
/// decorative; hidden or reduced-motion views contain no animation timeline.
struct PermissionStarfieldBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var windowIsVisible = false
    @State private var origin = Date()
    private let isVisible: Bool
    private let reduceMotionOverride: Bool?
    private let onAnimationTick: ((TimeInterval) -> Void)?

    /// The optional observer lets the local render harness verify that hidden
    /// windows stop ticking. Explicit local diagnostics can also observe ticks.
    init(isVisible: Bool = true, reduceMotionOverride: Bool? = nil,
         onAnimationTick: ((TimeInterval) -> Void)? = nil) {
        self.isVisible = isVisible
        self.reduceMotionOverride = reduceMotionOverride
        self.onAnimationTick = onAnimationTick
    }

    private var animates: Bool {
        isVisible && appeared && windowIsVisible && !(reduceMotionOverride ?? reduceMotion)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.012), Color(white: 0.003)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { tick in
                    stars(time: max(0, tick.date.timeIntervalSince(origin)), moving: true)
                        .onChange(of: tick.date) { _, date in
                            onAnimationTick?(max(0, date.timeIntervalSince(origin)))
                        }
                }
            } else {
                stars(time: 0, moving: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(PermissionStarfieldVisibility { windowIsVisible = $0 })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }

    private func stars(time: TimeInterval, moving: Bool) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            for star in Self.particles.prefix(Self.particleCount(for: size)) {
                let point = CGPoint(x: star.x * size.width, y: star.y * size.height)
                let intensity: Double
                if moving {
                    let phase = (time / star.period + star.phase).truncatingRemainder(dividingBy: 1)
                    // A smooth rise and fall, followed by a short dark pause.
                    // Independent phases and periods stagger the visible spots.
                    let glow = phase < star.litFraction ? sin(phase / star.litFraction * .pi) : 0
                    intensity = glow * glow
                } else {
                    intensity = 0.76 + 0.24 * sin(star.phase * .pi * 2)
                }
                let opacity = star.opacity * intensity
                let core = CGRect(x: point.x - star.diameter / 2, y: point.y - star.diameter / 2,
                                  width: star.diameter, height: star.diameter)
                context.fill(Path(ellipseIn: core.insetBy(dx: -1.25, dy: -1.25)),
                             with: .color(.white.opacity(opacity * 0.08)))
                context.fill(Path(ellipseIn: core), with: .color(.white.opacity(opacity)))
            }
            if moving { Self.drawMeteor(context: &context, size: size, time: time) }
        }
        .blur(radius: 0.35)
    }

    private struct Star {
        let x: Double
        let y: Double
        let diameter: Double
        let opacity: Double
        let phase: Double
        let period: Double
        let litFraction: Double
    }

    /// Preserve the small preview's density as the permission window grows,
    /// with a hard ceiling so a large display cannot create unbounded work.
    static func particleCount(for size: CGSize) -> Int {
        let area = max(0, size.width) * max(0, size.height)
        guard area.isFinite else { return 150 }
        let scaled = min(150.0, 44 * sqrt(area / (360 * 240)))
        return max(28, Int(scaled.rounded()))
    }

    private static let particles: [Star] = (0..<150).map { index in
        Star(x: 0.035 + noise(index, 1) * 0.93,
             y: 0.025 + noise(index, 2) * 0.95,
             diameter: 1.0 + noise(index, 3) * 1.0,
             opacity: 0.45 + noise(index, 4) * 0.35,
             phase: noise(index, 5),
             period: 1.8 + noise(index, 6) * 2.2,
             litFraction: 0.65 + noise(index, 7) * 0.15)
    }

    /// One faint streak, under 34 points long, with a quiet gap between passes.
    private static func drawMeteor(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let interval = 4.5
        let cycle = Int(time / interval)
        let elapsed = time.truncatingRemainder(dividingBy: interval) - 1
        let duration = 2.1
        guard elapsed >= 0, elapsed < duration else { return }
        let progress = elapsed / duration
        let opacity = sin(progress * .pi) * 0.62
        let travel = 65 + noise(cycle, 8) * 35
        let length = 20 + noise(cycle, 9) * 13
        // Side-card stacks reach the window edges. Keep every streak in the
        // free band above the cards, between the logo and permission counter.
        let start = CGPoint(x: (0.25 + noise(cycle, 10) * 0.20) * size.width,
                            y: (0.04 + noise(cycle, 11) * 0.012) * size.height)
        let direction = CGVector(dx: 0.995, dy: 0.10)
        let head = CGPoint(x: start.x + travel * progress * direction.dx,
                           y: start.y + travel * progress * direction.dy)
        let tail = CGPoint(x: head.x - length * direction.dx, y: head.y - length * direction.dy)
        var path = Path()
        path.move(to: tail); path.addLine(to: head)
        context.stroke(path, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(opacity)]),
            startPoint: tail, endPoint: head), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
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
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
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
                let canBeSeen = visible && !self.isHiddenOrHasHiddenAncestor && NSApp?.isHidden != true
                guard self.lastValue != canBeSeen else { return }
                self.lastValue = canBeSeen
                self.changed?(canBeSeen)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
