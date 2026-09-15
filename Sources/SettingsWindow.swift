import AppKit

/// The settings surface participates in ordinary macOS window management.
/// Privacy and camera overlays own their own elevated panels.
@MainActor final class AirVeilSettingsWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "AirVeil"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 740, height: 660)
        level = .normal
        collectionBehavior = [.managed, .participatesInCycle]
        isExcludedFromWindowsMenu = false
    }

    func showSettings() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
