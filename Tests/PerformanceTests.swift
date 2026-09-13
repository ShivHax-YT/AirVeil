import AppKit
import CoreVideo
import Darwin

/// GPU-only throughput evidence using synthesized IOSurface frames. This does not
/// request screen capture, read desktop pixels, or measure sensor-to-display latency.
@main struct PerformanceTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let display = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }), let mode = CGDisplayCopyDisplayMode(display) else {
            throw VeilRenderError.unavailable("Could not inspect the primary display dimensions.")
        }
        let width = mode.pixelWidth, height = mode.pixelHeight
        let scale = Double(width) / Double(screen.frame.width)
        let view = VeilMetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.isPaused = true
        if let error = view.initializationError { throw VeilRenderError.unavailable(error) }
        view.sourcePixelScale = scale
        view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        let mailbox = VeilFrameMailbox()
        view.frameMailbox = mailbox

        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { throw VeilRenderError.unavailable("Could not allocate a synthetic IOSurface.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw VeilRenderError.unavailable("Synthetic buffer has no storage.") }
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = ((x/12 + y/12) % 2 == 0) ? 0xFFF0F0F0 : 0xFF152435 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let warmup = 12, count = 120
        var durations: [Double] = []
        var memory: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        for frame in 0..<(warmup + count) {
            try autoreleasepool {
                // The preceding offscreen call has completed the GPU command, so
                // this owned test surface can be mutated without CPU/GPU racing.
                CVPixelBufferLockBaseAddress(buffer, [])
                let row = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
                for x in 0..<min(width, 256) { row[x] = 0xFF000000 | UInt32((x * 7919 + frame * 65537) & 0x00FFFFFF) }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                mailbox.put(buffer)
                _ = try view.renderOffscreen(width: width, height: height)
                if frame >= warmup { durations.append(view.lastGPUTimeMS) }
            }
            if frame == warmup - 1 || (frame + 1 - warmup) % 30 == 0 && frame >= warmup {
                memory.append(["measuredFramesCompleted": max(0, frame + 1 - warmup), "residentBytes": residentBytes()])
            }
        }
        guard durations.count == count, durations.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw VeilRenderError.unavailable("GPU completion timestamps were not valid.")
        }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]

        // Releasing a view disconnects and invalidates the mailbox immediately.
        // Confirm neither an old nor a newly offered pending frame survives it.
        mailbox.put(buffer)
        view.releaseCapturedResources()
        precondition(view.frameMailbox == nil && view.isPaused, "Pause must detach capture and stop drawing")
        precondition(mailbox.take() == nil, "Pause must release the pending source")
        mailbox.put(buffer)
        precondition(mailbox.take() == nil, "An invalidated mailbox must reject late frames")
        var rejectedRenderAfterRelease = false
        do { _ = try view.renderOffscreen(width: width, height: height) }
        catch { rejectedRenderAfterRelease = true }
        precondition(rejectedRenderAfterRelease, "Released pixels must not remain renderable")

        let repeatedCycles = 8
        for _ in 0..<repeatedCycles {
            try autoreleasepool {
                let resumedMailbox = VeilFrameMailbox()
                view.frameMailbox = resumedMailbox
                resumedMailbox.put(buffer)
                let image = try view.renderOffscreen(width: width, height: height)
                let bytes = image.dataProvider!.data! as Data
                precondition(bytes[3] == 0 && bytes[(width - 1) * 4 + 3] == 255,
                             "A reused view must recreate kernels and preserve directional alpha")
                view.releaseCapturedResources()
                resumedMailbox.put(buffer)
                precondition(!resumedMailbox.hasPending && resumedMailbox.take() == nil,
                             "Every release must reject old-session frames")
            }
        }

        let report: [String: Any] = [
            "kind": "synthetic-full-resolution-gpu-benchmark",
            "capturedPrivateScreenPixels": false,
            "timestampUTC": ISO8601DateFormatter().string(from: Date()),
            "widthPixels": width, "heightPixels": height, "pixelsPerPoint": scale,
            "blurSigmaPoints": 32, "blurLevels": 3,
            "warmupFrames": warmup, "measuredChangedFrames": count,
            "gpuMedianMilliseconds": median, "gpuP95Milliseconds": p95,
            "gpuMinimumMilliseconds": sorted.first!, "gpuMaximumMilliseconds": sorted.last!,
            "provisionalP95Under8Milliseconds": p95 < 8,
            "residentMemorySamples": memory,
            "releaseAndLateFrameAssertionsPassed": true,
            "successfulRepeatedReleaseAndRestartCycles": repeatedCycles,
            "wallSecondsIncludingSynchronousReadback": ProcessInfo.processInfo.systemUptime - started,
            "limitations": "Measures completed blit, three MPS Gaussian passes and compositor GPU work. Includes synchronous offscreen readback between submissions. Does not establish display cadence, capture latency, motion latency, or sustained live app memory."
        ]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/performance-metrics.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(String(format: "Synthetic %d×%d, %d changed frames: GPU median %.3f ms, p95 %.3f ms", width, height, count, median, p95))
        print("PASS: explicit release discards source and rejects late frames; \(repeatedCycles) repeated reuse/release cycles")
        print("Metrics: \(output.path)")
        print("This is GPU work measurement, not measured end-to-end FPS or live capture latency.")
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
