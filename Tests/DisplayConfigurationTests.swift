import AppKit

@main struct DisplayConfigurationTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            checks += 1
            precondition(value(), reason)
        }
        func display(_ id: UInt32 = 1, stableID: String = "built-in", x: Double = 0,
                     width: Double = 1512, scale: Double = 2, pixels: Int = 3024,
                     menuBand: Double = 37) -> VeilDisplayCaptureLayout {
            VeilDisplayCaptureLayout(id: id, stableID: stableID,
                frame: NSRect(x: x, y: 0, width: width, height: 982), backingScale: scale,
                pixelWidth: pixels, pixelHeight: 1964, menuBand: menuBand)
        }
        let builtIn = display(), external = display(2, stableID: "external", x: 1512)
        var guardState = VeilDisplayConfigurationGuard()
        var rebuilds = 0
        func notify(_ layout: [VeilDisplayCaptureLayout]?, running: Bool = true) {
            if guardState.shouldRebuild(current: layout, isRunning: running) { rebuilds += 1 }
        }
        notify([builtIn], running: false)
        check(rebuilds == 0, "An inactive controller never rebuilds on a display notification")
        guardState.begin([builtIn, external])
        for _ in 0..<100 { notify([builtIn, external]); notify([external, builtIn]) }
        check(rebuilds == 0, "Repeated no-op notifications and enumeration reordering preserve running capture")
        notify([builtIn], running: false)
        notify([builtIn, external])
        check(rebuilds == 0, "A notification while startup is not running cannot poison its committed layout")
        notify([builtIn])
        check(rebuilds == 1, "Disconnecting a display invalidates the active capture layout")
        notify([builtIn]); notify([builtIn])
        check(rebuilds == 1, "Duplicate notifications after a real change cannot recreate fault covers")
        notify([external, builtIn])
        check(rebuilds == 2, "A subsequent actual attachment invalidates again while fault coverage is active")
        for (name, changed) in [
            ("display identity", display(stableID: "replacement")),
            ("capture ID", display(9)),
            ("position", display(x: -300)),
            ("point size", display(width: 1280)),
            ("backing scale", display(scale: 1)),
            ("native pixel size", display(pixels: 2560)),
            ("menu input exclusion", display(menuBand: 25))
        ] {
            guardState.begin([builtIn])
            let oldCount = rebuilds
            notify([changed])
            check(rebuilds == oldCount + 1, "An actual \(name) change still triggers capture reconstruction")
            notify([changed])
            check(rebuilds == oldCount + 1, "The same \(name) change is processed only once")
        }
        guardState.begin([builtIn]); let beforeUnknown = rebuilds
        notify(nil)
        check(rebuilds == beforeUnknown + 1, "Losing readable display identity cannot silently reuse current capture")
        notify(nil)
        check(rebuilds == beforeUnknown + 1, "Repeated unknown inventory does not repeatedly rebuild fault covers")
        notify([builtIn])
        check(rebuilds == beforeUnknown + 2, "A recovered display identity rebuilds the unknown fault layout")
        guardState.stop(); let beforeStopped = rebuilds
        notify([external], running: false)
        check(rebuilds == beforeStopped, "Stop disarms configuration-triggered capture work")
        guardState.begin([external])
        notify([external]); notify([external])
        check(rebuilds == beforeStopped, "Re-enable owns a fresh baseline and does not inherit the prior display setup")
        notify([])
        check(rebuilds == beforeStopped + 1, "Removing every display still invalidates running capture")
        print("PASS: \(checks) capture-owner display notification decisions; synthetic layouts, no capture or windows")
    }
}
