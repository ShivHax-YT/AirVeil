import Foundation
import CoreGraphics

/// Screen coordinates are AppKit points, including screens with negative origins.
struct NotchGeometry: Equatable {
    let screen: CGRect
    let cutout: CGRect
    let hasNotch: Bool

    init(screen: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        self.screen = screen
        if safeTop > 0, let leftArea, let rightArea,
           rightArea.minX > leftArea.maxX {
            hasNotch = true
            cutout = CGRect(x: leftArea.maxX, y: screen.maxY - safeTop,
                            width: rightArea.minX - leftArea.maxX, height: safeTop)
        } else {
            hasNotch = false
            cutout = CGRect(x: screen.midX - 86, y: screen.maxY - 32, width: 172, height: 0)
        }
    }

    var topInset: CGFloat { hasNotch ? cutout.height : 0 }
    var hardwareWidth: CGFloat { cutout.width }
    var hoverRect: CGRect {
        CGRect(x: cutout.minX - 8, y: cutout.minY - 8,
               width: cutout.width + 16, height: max(cutout.height, 8) + 8)
    }
    func panelFrame(width: CGFloat, contentHeight: CGFloat) -> CGRect {
        let width = min(width, screen.width - 24)
        let top = hasNotch ? screen.maxY : screen.maxY - 38
        return CGRect(x: min(screen.maxX - width - 12, max(screen.minX + 12, cutout.midX - width / 2)),
                      y: top - topInset - contentHeight, width: width, height: topInset + contentHeight)
    }
}
