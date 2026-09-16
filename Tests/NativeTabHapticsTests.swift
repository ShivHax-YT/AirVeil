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
        window.orderOut(nil)
        print("PASS: native TabView selection emits one immediate pulse; initial, duplicate, programmatic and opt-out transitions stay silent")
    }
}
