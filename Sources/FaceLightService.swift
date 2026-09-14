import AppKit
import CoreGraphics

/// AirVeil's own screen illumination, separate from Apple's Video Effects.
/// It never changes backlight brightness, wakes the display, or retains an
/// enabled preference. The camera owner must turn it off at every stop.
@MainActor protocol FaceLighting: AnyObject {
    var isOn: Bool { get }
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool
}

@MainActor final class FaceLightService: FaceLighting {
    private(set) var isOn = false
    private var panel: FaceLightPanel?

    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            panel?.orderOut(nil)
            panel = nil
            isOn = false
            return true
        }
        if isOn { return true }
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        }) else { return false }
        let window = FaceLightPanel(contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none
        window.contentView = FaceLightBorder(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.alphaValue = 0
        panel = window
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }
        isOn = true
        return true
    }
}

@MainActor private final class FaceLightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class FaceLightBorder: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        // The transparent middle leaves the check and desktop readable. The
        // broad warm-white border provides actual light from display pixels.
        let outer = bounds.insetBy(dx: 5, dy: 5)
        let inner = bounds.insetBy(dx: 42, dy: 42)
        let ring = NSBezierPath(roundedRect: outer, xRadius: 28, yRadius: 28)
        ring.append(NSBezierPath(roundedRect: inner, xRadius: 22, yRadius: 22))
        ring.windingRule = .evenOdd
        NSColor(calibratedRed: 1, green: 0.98, blue: 0.94, alpha: 0.98).setFill()
        ring.fill()
    }
}
