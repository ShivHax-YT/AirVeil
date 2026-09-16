import SwiftUI
import AppKit
import QuartzCore

/// Decorative particles are built once and animated by the compositor. There is
/// no SwiftUI per-frame invalidation or drawing loop, and no fixed refresh cap.
struct PermissionStarfieldBackground: View {
    enum MeteorPlacement: Equatable {
        case permissions, settings
        var verticalFraction: Double { self == .permissions ? 0.04 : 0.075 }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isVisible: Bool
    private let placement: MeteorPlacement
    private let reduceMotionOverride: Bool?
    private let onAnimationTick: ((TimeInterval) -> Void)?

    /// A display-link observer is installed only for explicit local diagnostics;
    /// the shipped UI does not need a CPU callback to animate these layers.
    init(placement: MeteorPlacement = .permissions, isVisible: Bool = true, reduceMotionOverride: Bool? = nil,
         onAnimationTick: ((TimeInterval) -> Void)? = nil) {
        self.isVisible = isVisible
        self.placement = placement
        self.reduceMotionOverride = reduceMotionOverride
        self.onAnimationTick = onAnimationTick
    }

    var body: some View {
        StarfieldLayers(placement: placement, enabled: isVisible && !(reduceMotionOverride ?? reduceMotion),
                        onAnimationTick: onAnimationTick)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    static func particleCount(for size: CGSize) -> Int {
        let area = max(0, size.width) * max(0, size.height)
        guard area.isFinite else { return 150 }
        return max(28, Int(min(150.0, 44 * sqrt(area / (360 * 240))).rounded()))
    }
}

private struct StarfieldLayers: NSViewRepresentable {
    let placement: PermissionStarfieldBackground.MeteorPlacement
    let enabled: Bool
    let onAnimationTick: ((TimeInterval) -> Void)?

    func makeNSView(context: Context) -> StarfieldLayerView { StarfieldLayerView() }
    func updateNSView(_ view: StarfieldLayerView, context: Context) {
        view.configure(placement: placement, enabled: enabled, observer: onAnimationTick)
    }
    static func dismantleNSView(_ view: StarfieldLayerView, coordinator: ()) { view.tearDown() }
}

/// Internal for the generated-art harness to inspect real animation/presentation
/// state without taking a screenshot of the user's desktop.
final class StarfieldLayerView: NSView {
    private struct Star {
        let x, y, diameter, opacity, phase, period, litFraction: Double
    }
    private static let particles: [Star] = (0..<150).map { index in
        Star(x: 0.035 + noise(index, 1) * 0.93, y: 0.025 + noise(index, 2) * 0.95,
             diameter: 1 + noise(index, 3), opacity: 0.45 + noise(index, 4) * 0.35,
             phase: noise(index, 5), period: 1.8 + noise(index, 6) * 2.2,
             litFraction: 0.65 + noise(index, 7) * 0.15)
    }
    private let backdrop = CAGradientLayer()
    private var stars: [CALayer] = []
    private var meteors: [CALayer] = []
    private var placement = PermissionStarfieldBackground.MeteorPlacement.permissions
    private var enabled = false
    private(set) var animationsRunning = false
    var activeAnimationCount: Int {
        (stars + meteors).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }
    private var refreshScheduled = false
    private var lastSize = CGSize.zero
    private var observer: ((TimeInterval) -> Void)?
    private var diagnosticLink: CADisplayLink?
    private let origin = CACurrentMediaTime()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.colors = [NSColor(white: 0.012, alpha: 1).cgColor, NSColor(white: 0.003, alpha: 1).cgColor]
        backdrop.startPoint = CGPoint(x: 0, y: 0)
        backdrop.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(backdrop)
        for star in Self.particles {
            let particle = CAGradientLayer()
            particle.type = .radial
            particle.startPoint = CGPoint(x: 0.5, y: 0.5)
            particle.endPoint = CGPoint(x: 1, y: 1)
            particle.colors = [NSColor.white.cgColor, NSColor.white.cgColor,
                               NSColor.white.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
            particle.locations = [0, 0.22, 0.40, 1]
            particle.bounds = CGRect(x: 0, y: 0, width: star.diameter + 2.5, height: star.diameter + 2.5)
            particle.opacity = Float(star.opacity * (0.76 + 0.24 * sin(star.phase * .pi * 2)))
            stars.append(particle)
            layer?.addSublayer(particle)
        }
        // A deterministic sequence preserves varied trails without CPU work on
        // each pass. Only one of these tiny layers is visible at any instant.
        for index in 0..<12 {
            let meteor = CAGradientLayer()
            meteor.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
            meteor.startPoint = CGPoint(x: 0, y: 0.5)
            meteor.endPoint = CGPoint(x: 1, y: 0.5)
            meteor.bounds = CGRect(x: 0, y: 0, width: 20 + Self.noise(index, 9) * 13, height: 1)
            meteor.anchorPoint = CGPoint(x: 1, y: 0.5)
            meteor.transform = CATransform3DMakeRotation(atan2(0.10, 0.995), 0, 0, 1)
            meteor.opacity = 0
            meteors.append(meteor)
            layer?.addSublayer(meteor)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(placement: PermissionStarfieldBackground.MeteorPlacement, enabled: Bool,
                   observer: ((TimeInterval) -> Void)?) {
        if self.placement != placement {
            self.placement = placement
            lastSize = .zero
            needsLayout = true
        }
        self.enabled = enabled
        self.observer = observer
        scheduleRefresh()
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        let count = PermissionStarfieldBackground.particleCount(for: bounds.size)
        for (index, particle) in stars.enumerated() {
            let star = Self.particles[index]
            particle.position = CGPoint(x: star.x * bounds.width, y: star.y * bounds.height)
            particle.isHidden = index >= count
        }
        CATransaction.commit()
        // Only bounds changes rebuild meteor paths; normal SwiftUI updates do not.
        if animationsRunning { installMeteorAnimations() }
        scheduleRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
        }
        scheduleRefresh()
    }
    override func viewDidHide() { super.viewDidHide(); scheduleRefresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleRefresh() }
    @objc private func visibilityChanged(_ note: Notification) { scheduleRefresh() }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Closing/occlusion notifications can precede the actual window change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let visible = self.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            self.setAnimating(self.enabled && visible && !self.isHiddenOrHasHiddenAncestor && NSApp?.isHidden != true)
        }
    }

    private func setAnimating(_ active: Bool) {
        if active != animationsRunning {
            animationsRunning = active
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, particle) in stars.enumerated() {
                particle.removeAllAnimations()
                let star = Self.particles[index]
                if active {
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    // Sample the original sine-squared twinkle once, then let CA
                    // interpolate at the display's cadence rather than 18 Hz.
                    animation.values = (0...48).map { sample -> NSNumber in
                        let phase = Double(sample) / 48
                        let glow = phase < star.litFraction ? sin(phase / star.litFraction * .pi) : 0
                        return NSNumber(value: star.opacity * glow * glow)
                    }
                    animation.beginTime = particle.convertTime(origin, from: nil)
                    animation.duration = star.period
                    animation.timeOffset = star.phase * star.period
                    animation.repeatCount = .infinity
                    particle.add(animation, forKey: "twinkle")
                }
            }
            if active { installMeteorAnimations() }
            else { meteors.forEach { $0.removeAllAnimations() } }
            CATransaction.commit()
        }
        if active && observer != nil && diagnosticLink == nil {
            diagnosticLink = displayLink(target: self, selector: #selector(observePresentation))
            diagnosticLink?.add(to: .main, forMode: .common)
        } else if !active || observer == nil {
            diagnosticLink?.invalidate()
            diagnosticLink = nil
        }
    }

    private func installMeteorAnimations() {
        let sequenceDuration = 4.5 * Double(meteors.count)
        for (index, meteor) in meteors.enumerated() {
            meteor.removeAllAnimations()
            let start = CGPoint(x: (0.25 + Self.noise(index, 10) * 0.20) * bounds.width,
                                y: (placement.verticalFraction + Self.noise(index, 11) * 0.012) * bounds.height)
            let travel = 65 + Self.noise(index, 8) * 35
            let end = CGPoint(x: start.x + travel * 0.995, y: start.y + travel * 0.10)
            let begin = Double(index) * 4.5 + 1
            let finish = begin + 2.1
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = [NSValue(point: start), NSValue(point: start), NSValue(point: end), NSValue(point: end)]
            position.keyTimes = [0, NSNumber(value: begin / sequenceDuration), NSNumber(value: finish / sequenceDuration), 1]
            position.duration = sequenceDuration
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0] + (0...32).map { NSNumber(value: sin(Double($0) / 32 * .pi) * 0.62) } + [0]
            opacity.keyTimes = [0] + (0...32).map { NSNumber(value: (begin + Double($0) / 32 * 2.1) / sequenceDuration) } + [1]
            opacity.duration = sequenceDuration
            let group = CAAnimationGroup()
            group.animations = [position, opacity]
            group.beginTime = meteor.convertTime(origin, from: nil)
            group.duration = sequenceDuration
            group.repeatCount = .infinity
            meteor.add(group, forKey: "meteor")
        }
    }

    @objc private func observePresentation(_ link: CADisplayLink) {
        guard animationsRunning, stars.first?.animation(forKey: "twinkle") != nil else { return }
        observer?(max(0, link.timestamp - origin))
    }

    func tearDown() {
        enabled = false
        observer = nil
        setAnimating(false)
        NotificationCenter.default.removeObserver(self)
    }
    deinit { diagnosticLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private static func noise(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index * 73 + salt * 199 + 17) * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}
