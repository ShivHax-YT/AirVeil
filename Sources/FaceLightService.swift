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
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none
        window.contentView = FaceLightBorder(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.alphaValue = 0
        panel = window
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
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

/// A concentric rounded rectangle gives the broad, even light frame shown in
/// the reference, with a transparent center and no changes to panel brightness.
struct FaceLightGeometry {
    let outer: CGRect
    let inner: CGRect
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    init(bounds: CGRect) {
        let side = min(bounds.width, bounds.height)
        let margin = max(8, side * 0.012)
        let thickness = min(52, max(24, side * 0.045))
        outer = bounds.insetBy(dx: margin, dy: margin)
        inner = outer.insetBy(dx: thickness, dy: thickness)
        outerRadius = min(120, max(48, side * 0.14))
        innerRadius = max(8, outerRadius - thickness)
    }
    var path: NSBezierPath {
        let ring = NSBezierPath(roundedRect: outer, xRadius: outerRadius, yRadius: outerRadius)
        ring.append(NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius))
        ring.windingRule = .evenOdd
        return ring
    }
}

@MainActor final class FaceLightBorder: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let ring = FaceLightGeometry(bounds: bounds).path
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.white.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 16
        glow.shadowOffset = .zero
        glow.set()
        NSColor(calibratedRed: 1, green: 0.99, blue: 0.97, alpha: 1).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
