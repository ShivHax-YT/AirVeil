import AppKit

@main @MainActor struct SettingsWindowTests {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            checks += 1
            precondition(value(), reason)
        }
        let window = AirVeilSettingsWindow(contentRect: CGRect(x: 80, y: 80, width: 760, height: 680))
        defer { window.close() }
        let requiredContentSize = NSSize(width: 740, height: 660)
        let minimumContentRect = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.minSize))
        check(minimumContentRect.width >= requiredContentSize.width && minimumContentRect.height >= requiredContentSize.height,
              "The minimum titled window frame leaves enough content space for Settings and Permissions")
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        let constrainedContentRect = window.contentRect(forFrameRect: window.frame)
        check(constrainedContentRect.width >= requiredContentSize.width && constrainedContentRect.height >= requiredContentSize.height,
              "The actual window at its minimum frame size preserves the full Settings and Permissions layout")
        if CommandLine.arguments.contains("--geometry-only") {
            print("PASS: \(checks) native Settings minimum-size checks; no windows shown")
            return
        }
        window.setContentSize(NSSize(width: 760, height: 680))
        let other = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 250),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        func drain() async { try? await Task.sleep(nanoseconds: 80_000_000) }
        check(window.level == .normal && window.canBecomeKey,
              "Settings is an ordinary focusable window at the normal level")
        check(window.collectionBehavior.contains(.managed) && window.collectionBehavior.contains(.participatesInCycle),
              "Settings participates in macOS managed windows and window cycling")
        check(!window.collectionBehavior.contains(.ignoresCycle) && !window.isExcludedFromWindowsMenu,
              "Settings is available to the Window menu and window switcher")
        check(window.styleMask.contains(.miniaturizable) && window.styleMask.contains(.closable),
              "Settings supports native close and minimize controls")
        window.showSettings()
        await drain()
        let originalWindowNumber = window.windowNumber
        check(window.isVisible && !window.isMiniaturized && window.canBecomeMain, "Opening settings presents an ordinary main window")
        other.makeKeyAndOrderFront(nil)
        await drain()
        let ordered = app.orderedWindows
        check(ordered.firstIndex(of: other)! < ordered.firstIndex(of: window)!,
              "Another normal window can cover Settings without minimizing it")
        check(window.level == .normal, "Losing focus does not elevate Settings")
        window.close()
        await drain()
        check(!window.isVisible, "Closing Settings removes its window")
        window.showSettings()
        await drain()
        check(window.isVisible && window.windowNumber == originalWindowNumber,
              "Reopening after close reuses the registered capture exception")
        check(window.level == .normal, "Reopening never makes Settings float above other apps")
        print("PASS: \(checks) native Settings window checks; no camera, motion, screen capture, dimming, or lock")
        print("Dock minimization and app switching require installed-app UI verification.")
    }
}
