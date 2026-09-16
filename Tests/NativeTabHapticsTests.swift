import AppKit
import SwiftUI

@MainActor private final class NativeTabHapticProbe {
    var raw: Binding<Int>?
    var pulses: [InteractionHaptics.Pulse] = []
    var enabled = true
    lazy var feedback = InteractionHaptics(enabled: { [weak self] in self?.enabled ?? false }, perform: { [weak self] in self?.pulses.append($0) })
}
private struct TabHapticHarness: View {
    @State private var selected = 0
    let probe: NativeTabHapticProbe
    var body: some View {
        TabView(selection: $selected.hapticTabSelection(using: probe.feedback)) {
            ForEach(0..<5) { index in
                Text("Page \(index)").tabItem { Text(["Preview", "Tracking", "Displays", "Appearance", "Power"][index]) }.tag(index)
            }
        }.onAppear { probe.raw = $selected }
    }
}
@main @MainActor struct NativeTabHapticsTests {
    static func pump() async { try? await Task.sleep(for: .milliseconds(150)) }
    static func segmented(_ view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for child in view.subviews { if let control = segmented(child) { return control } }
        return nil
    }
    static func main() async {
        _ = NSApplication.shared
        let probe = NativeTabHapticProbe()
        let host = NSHostingView(rootView: TabHapticHarness(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 740,height: 660), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        await pump()
        guard let control = segmented(window.contentView!.superview!) else { fatalError("Native tab control missing") }
        precondition((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["Preview", "Tracking", "Displays", "Appearance", "Power"], "Native labels identify only the Settings tabs")
        precondition(probe.pulses.isEmpty, "Initial mounting must be silent")
        var expectedPulses = 0
        for index in [1, 2, 3, 4, 3, 2, 1, 0] {
            control.selectedSegment = index
            precondition(control.sendAction(control.action, to: control.target))
            expectedPulses += 1
            precondition(probe.raw?.wrappedValue == index && probe.pulses.count == expectedPulses, "Native tab action must pulse immediately")
            await pump()
            precondition(probe.pulses.count == expectedPulses, "No deferred duplicate")
        }
        _ = control.sendAction(control.action, to: control.target)
        precondition(probe.pulses.count == expectedPulses, "Same selection stays silent")
        probe.raw?.wrappedValue = 3
        await pump()
        precondition(probe.pulses.count == expectedPulses && control.selectedSegment == 3, "Programmatic tour-style update stays silent")
        probe.enabled = false
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        await pump()
        precondition(probe.raw?.wrappedValue == 1 && probe.pulses.count == expectedPulses, "Opt-out preserves navigation")
        // Exercise the exact native hit-testing route without posting synthetic
        // events to the user's desktop or invoking the physical performer.
        let observer = TabPressObserverView(frame: .zero)
        observer.titles = ["Preview", "Tracking", "Displays", "Appearance", "Power"]
        observer.feedback = probe.feedback
        host.addSubview(observer)
        probe.enabled = true
        let point = control.convert(NSPoint(x: control.bounds.width / 10, y: control.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        observer.beginPress(event)
        precondition(probe.pulses.count == expectedPulses + 1, "Native tab press hit-test must emit before selection")
        precondition(probe.pulses.last == .selection)
        observer.sample(location: NSPoint(x: control.bounds.width * 0.9, y: control.bounds.midY), initial: true)
        precondition(probe.pulses.count == expectedPulses + 2, "Crossing tab boundaries must emit")
        observer.sample(location: NSPoint(x: control.bounds.width * 0.9, y: control.bounds.midY), initial: false)
        precondition(probe.pulses.count == expectedPulses + 2, "Stationary pointer must remain silent")
        observer.stopObserving()
        observer.removeFromSuperview()
        window.orderOut(nil)
        print("PASS: native TabView selection emits one immediate pulse; initial, duplicate, programmatic and opt-out transitions stay silent")
    }
}
