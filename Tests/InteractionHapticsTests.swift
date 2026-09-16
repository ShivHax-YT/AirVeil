import AppKit
import SwiftUI

@main @MainActor struct InteractionHapticsTests {
    static func main() {
        var enabled = true
        var now = 0.0
        var pulses: [InteractionHaptics.Pulse] = []
        let haptics = InteractionHaptics(enabled: { enabled }, clock: { now }, perform: { pulses.append($0) })
        var value = 0.0
        let source = Binding(get: { value }, set: { value = $0 })
        let slider = source.hapticMovement(in: 0...100, using: haptics)
        value = 30
        precondition(slider.wrappedValue == 30 && pulses.isEmpty, "Programmatic updates must be silent")
        slider.wrappedValue = 30
        slider.wrappedValue = 30.5
        precondition(pulses.isEmpty, "Stationary input and sub-detent movement must be silent")
        slider.wrappedValue = 33
        precondition(pulses == [.tick])
        for n in 34...90 { now += 0.0001; slider.wrappedValue = Double(n) }
        precondition(pulses == [.tick] && value == 90, "Fast input remains direct without queued ticks")
        now = 0.1; slider.wrappedValue = 100
        precondition(pulses == [.tick, .boundary])
        now = 0.2; slider.wrappedValue = 100
        precondition(pulses.count == 2, "Clamped endpoints must not repeat")
        slider.wrappedValue = 97
        precondition(pulses.last == .tick, "Reversing must produce detents")
        now = 0.3; slider.wrappedValue = 0
        precondition(pulses.last == .boundary)
        let count = pulses.count
        haptics.movement(from: .nan, to: 10, in: 0...100)
        haptics.movement(from: 1, to: .infinity, in: 0...100)
        haptics.movement(from: 1, to: 2, in: 0...0)
        precondition(pulses.count == count)
        enabled = false; now = 1
        slider.wrappedValue = 50; haptics.action()
        precondition(value == 50 && pulses.count == count, "Preference disables effects, not input")
        var selection = false
        let toggle = Binding(get: { selection }, set: { selection = $0 }).hapticSelection(using: haptics)
        enabled = true
        toggle.wrappedValue = true
        precondition(selection && pulses.last == .action)
        let selectedCount = pulses.count
        toggle.wrappedValue = true
        selection = false
        _ = toggle.wrappedValue
        precondition(pulses.count == selectedCount, "Duplicate writes and external changes stay silent")
        let rejecting = Binding(get: { false }, set: { _ in }).hapticSelection(using: haptics)
        rejecting.wrappedValue = true
        precondition(pulses.count == selectedCount, "Rejected value must not produce feedback")
        // The existing system-selected step is preserved; detents never quantize input.
        now = 2; slider.wrappedValue = 51.234
        precondition(value == 51.234)
        print("PASS: haptic detents, rate limiting, endpoints, reversal, silent external/rejected updates, opt-out, direct binding; injected performer only")
    }
}
