import AppKit
import SwiftUI

@main struct LegalDocumentsRender {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for document in LegalDocument.allCases {
            guard let policy = document.text() else { fatalError("Missing bundled \(document.rawValue) policy") }
            precondition(policy.contains("shivhax@gmail.com"), "The published support contact must be available offline")
            precondition(!policy.contains("[INSERT") && !policy.contains("TODO"), "No drafting placeholders in bundled policies")
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let host = NSHostingView(rootView: LegalDocumentView(document: document)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let rect = CGRect(x: -20000, y: -20000, width: 700, height: 650)
                let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = host; host.appearance = appearance
                host.frame = CGRect(origin: .zero, size: rect.size)
                panel.orderFront(nil)
                try await Task.sleep(nanoseconds: 150_000_000)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    output.appendingPathComponent("\(document.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
                panel.close()
            }
        }
        print("PASS: All three bundled policies load offline with public contact; six native reader renders")
    }
}
