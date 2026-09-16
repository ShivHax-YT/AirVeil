import AppKit
import SwiftUI
import QuartzCore

/// A small UI-side effect service. Never observe model changes here: only
/// control actions and UI binding writes are allowed to request feedback.
@MainActor final class InteractionHaptics {
    enum Pulse: Equatable { case action, selection, tick, boundary }
    nonisolated static let preferenceKey = "trackpadFeedbackEnabled"
    static let shared = InteractionHaptics()
    private let enabled: () -> Bool
    private let clock: () -> TimeInterval
    private let perform: @MainActor (Pulse) -> Void
    private var lastTick = -Double.infinity
    private var tabPressActive = false
    private var tabPressEnded = -Double.infinity

    init(enabled: @escaping () -> Bool = {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }, clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         perform: @escaping @MainActor (Pulse) -> Void = { pulse in
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch pulse {
        case .action: pattern = .levelChange
        case .tick: pattern = .alignment
        case .selection, .boundary: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }) {
        self.enabled = enabled; self.clock = clock; self.perform = perform
    }

    func action() {
        guard enabled() else { return }
        perform(.action)
    }

    func selection() {
        guard !tabPressActive, clock() - tabPressEnded > 0.15, enabled() else { return }
        perform(.selection)
    }

    func beginTabPress() { tabPressActive = true }
    func endTabPress() { tabPressActive = false; tabPressEnded = clock() }
    func tabPressTick(initial: Bool) {
        guard enabled() else { return }
        perform(initial ? .selection : .tick)
    }

    /// Quantization affects feedback only; slider values remain continuous.
    /// No timers, queued pulses, or work proportional to skipped detents.
    func movement(from old: Double, to new: Double, in range: ClosedRange<Double>, step: Double? = nil) {
        let span = range.upperBound - range.lowerBound
        guard enabled(), old.isFinite, new.isFinite, span.isFinite, span > 0 else { return }
        let a = min(range.upperBound, max(range.lowerBound, old))
        let b = min(range.upperBound, max(range.lowerBound, new))
        guard a != b else { return }
        let spacing: Double
        if let step, step.isFinite, step > 0 {
            spacing = max(step, ceil(span / 40 / step) * step)
        } else {
            spacing = span / 40
        }
        guard spacing.isFinite, spacing > 0 else { return }
        let boundary = b == range.lowerBound || b == range.upperBound
        let crossed = floor((a - range.lowerBound) / spacing) != floor((b - range.lowerBound) / spacing)
        guard boundary || crossed else { return }
        let now = clock()
        guard now.isFinite, now - lastTick >= 0.045 else { return }
        lastTick = now
        perform(boundary ? .boundary : .tick)
    }
}

extension Binding where Value: Equatable {
    /// For locally owned tab state, where every proposed selection is valid.
    /// Request feedback before changing pages, while the input action is active.
    /// Tour navigation writes directly to state and bypasses this binding.
    @MainActor func hapticTabSelection(using feedback: InteractionHaptics? = nil) -> Binding<Value> {
        let feedback = feedback ?? .shared
        return Binding(get: { wrappedValue }, set: { next in
            if wrappedValue != next { feedback.selection() }
            wrappedValue = next
        })
    }

    /// The control calls this setter; programmatic model updates only hit get.
    @MainActor func hapticSelection(using feedback: InteractionHaptics? = nil) -> Binding<Value> {
        let feedback = feedback ?? .shared
        return Binding(get: { wrappedValue }, set: { next in
            let old = wrappedValue
            wrappedValue = next
            if old != wrappedValue { feedback.action() }
        })
    }
}

extension Binding where Value == Double {
    @MainActor func hapticMovement(in range: ClosedRange<Double>, step: Double? = nil,
                                  using feedback: InteractionHaptics? = nil) -> Binding<Double> {
        let feedback = feedback ?? .shared
        return Binding(get: { wrappedValue }, set: { next in
            let old = wrappedValue
            wrappedValue = next
            feedback.movement(from: old, to: wrappedValue, in: range, step: step)
        })
    }
}

/// Preserve the actual SwiftUI Button, including its inherited native glass,
/// disabled state, keyboard shortcut, accessibility role, and menu behavior.
@MainActor struct HapticButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    @Environment(\.isEnabled) private var isEnabled
    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action; self.label = label()
    }
    var body: some View {
        Button {
            guard isEnabled else { return }
            InteractionHaptics.shared.action()
            action()
        } label: { label }
    }
}
extension HapticButton where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}
extension HapticButton where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}

/// Uses the native slider recognizer, not an overlapping drag gesture.
@MainActor struct HapticSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil) {
        _value = value; self.range = range; self.step = step
    }
    @ViewBuilder var body: some View {
        if let step {
            Slider(value: $value.hapticMovement(in: range, step: step), in: range, step: step)
        } else {
            Slider(value: $value.hapticMovement(in: range), in: range)
        }
    }
}

/// Observe only presses in this window's native Settings tab control. The
/// native control keeps ownership of tracking, selection, and glass animation.
struct NativeTabPressFeedback: NSViewRepresentable {
    let titles: [String]
    func makeNSView(context: Context) -> TabPressObserverView {
        let view = TabPressObserverView()
        view.titles = titles
        return view
    }
    func updateNSView(_ view: TabPressObserverView, context: Context) { view.titles = titles }
    static func dismantleNSView(_ view: TabPressObserverView, coordinator: ()) { view.stopObserving() }
}

@MainActor final class TabPressObserverView: NSView {
    var titles: [String] = []
    var feedback = InteractionHaptics.shared
    private var monitor: Any?
    private var trackingTimer: Timer?
    private weak var trackedControl: NSSegmentedControl?
    private var ownsPress = false
    private var lastSegment: Int?
    private var lastPulse = -Double.infinity
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.beginPress(event) }
            return event
        }
    }
    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endPress()
    }
    func beginPress(_ event: NSEvent) {
        guard let window, event.window === window,
              let root = window.contentView?.superview else { return }
        var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        while let view = hit, !(view is NSSegmentedControl) { hit = view.superview }
        guard let control = hit as? NSSegmentedControl, control.isEnabled,
              control.segmentCount == titles.count,
              (0..<control.segmentCount).map({ control.label(forSegment: $0) }) == titles else { return }
        endPress()
        trackedControl = control
        ownsPress = true
        feedback.beginTabPress()
        sample(location: control.convert(event.locationInWindow, from: nil), initial: true)
        // Native cells can run their own event-tracking loop. Sampling in that
        // mode keeps boundary ticks synchronous with the glass drag, instead of
        // waiting for the selection binding's mouse-up callback.
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPress() }
        }
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func trackPress() {
        guard NSEvent.pressedMouseButtons & 1 != 0,
              let control = trackedControl, let window = control.window,
              window.isVisible, NSApp.isActive else { endPress(); return }
        sample(location: control.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), initial: false)
    }
    func sample(location: NSPoint, initial: Bool) {
        guard let control = trackedControl else { return }
        let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        guard let segment = Self.segment(at: location, bounds: control.bounds, widths: widths),
              control.isEnabled(forSegment: segment) else { lastSegment = nil; return }
        guard segment != lastSegment else { return }
        lastSegment = segment
        let now = CACurrentMediaTime()
        guard initial || now - lastPulse >= 0.045 else { return }
        lastPulse = now
        feedback.tabPressTick(initial: initial)
    }
    private func endPress() {
        trackingTimer?.invalidate(); trackingTimer = nil
        if ownsPress { feedback.endTabPress() }
        ownsPress = false
        trackedControl = nil; lastSegment = nil
    }
    static func segment(at point: NSPoint, bounds: NSRect, widths: [CGFloat]) -> Int? {
        guard bounds.contains(point), !widths.isEmpty, bounds.width > 0 else { return nil }
        let total = widths.reduce(0, +)
        let explicit = widths.allSatisfy { $0 > 0 } && total > 0
        var edge = bounds.minX
        for index in widths.indices {
            edge += explicit ? bounds.width * widths[index] / total : bounds.width / CGFloat(widths.count)
            if point.x < edge { return index }
        }
        return widths.count - 1
    }
}
