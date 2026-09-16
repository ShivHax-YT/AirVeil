import AppKit
import SwiftUI
import QuartzCore

/// A small UI-side effect service. Never observe model changes here: only
/// control actions and UI binding writes are allowed to request feedback.
@MainActor final class InteractionHaptics {
    enum Pulse: Equatable { case action, tick, boundary }
    nonisolated static let preferenceKey = "trackpadFeedbackEnabled"
    static let shared = InteractionHaptics()
    private let enabled: () -> Bool
    private let clock: () -> TimeInterval
    private let perform: @MainActor (Pulse) -> Void
    private var lastTick = -Double.infinity

    init(enabled: @escaping () -> Bool = {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }, clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         perform: @escaping @MainActor (Pulse) -> Void = { pulse in
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch pulse {
        case .action: pattern = .levelChange
        case .tick: pattern = .alignment
        case .boundary: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }) {
        self.enabled = enabled; self.clock = clock; self.perform = perform
    }

    func action() {
        guard enabled() else { return }
        perform(.action)
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
