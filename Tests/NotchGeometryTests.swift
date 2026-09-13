import Foundation
import CoreGraphics

@main struct NotchGeometryTests {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { fatalError(message) }
        }
        for origin in [CGPoint.zero, CGPoint(x: -1512, y: -400), CGPoint(x: 300, y: 1080)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
            let left = CGRect(x: screen.minX, y: screen.maxY - 32, width: 660, height: 32)
            let right = CGRect(x: screen.minX + 852, y: screen.maxY - 32, width: 660, height: 32)
            let geo = NotchGeometry(screen: screen, safeTop: 32, leftArea: left, rightArea: right)
            let panel = geo.panelFrame(width: 360, contentHeight: 260)
            check(geo.hasNotch && geo.hardwareWidth == 192 && geo.topInset == 32, "Read actual hardware geometry")
            check(panel.midX == geo.cutout.midX && panel.maxY == screen.maxY, "Anchor to notch on screens with nonzero origins")
            check(panel.minX >= screen.minX && panel.maxX <= screen.maxX, "Panel stays on target screen")
            check(geo.hoverRect.contains(CGPoint(x: screen.midX, y: screen.maxY - 34)), "Hover activation covers notch lower edge")
            let fallback = NotchGeometry(screen: screen, safeTop: 0, leftArea: nil, rightArea: nil)
            let floating = fallback.panelFrame(width: 360, contentHeight: 260)
            check(!fallback.hasNotch && fallback.topInset == 0, "External display needs no cutout padding")
            check(floating.maxY == screen.maxY - 38 && floating.midX == screen.midX, "Floating panel clears menu bar")
        }
        print("Passed \(checks) notch screen geometry checks")
    }
}
