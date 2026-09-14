import Foundation

@MainActor private final class ControlledUpdates {
    enum Failure: Error { case rejected }
    var requested: [Int] = []
    var active = 0
    var maximumActive = 0
    var continuation: CheckedContinuation<Void, Error>?

    func update(_ fps: Int) async throws {
        requested.append(fps)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(failing: Bool = false) {
        guard let pending = continuation else { preconditionFailure("No update pending") }
        continuation = nil
        if failing { pending.resume(throwing: Failure.rejected) }
        else { pending.resume() }
    }
}

@main @MainActor struct CaptureCadenceTests {
    static func main() async {
        // Actual production controller: rapid requests collapse before submission.
        let updates = ControlledUpdates()
        let cadence = CaptureCadenceController(initialFramesPerSecond: 60, update: updates.update)
        cadence.request(30); cadence.request(60)
        await drain()
        precondition(updates.requested.isEmpty && cadence.state == .idle)
        cadence.request(30)
        await drain()
        precondition(updates.requested == [30] && cadence.state == .updating)
        cadence.request(60); cadence.request(30); cadence.request(60)
        await drain()
        precondition(updates.requested == [30], "No overlapping stream configuration calls")
        updates.finish()
        await drain()
        precondition(updates.requested == [30, 60] && cadence.appliedFramesPerSecond == 30)
        updates.finish()
        await drain()
        precondition(cadence.appliedFramesPerSecond == 60 && cadence.desiredFramesPerSecond == 60 && cadence.state == .idle)
        precondition(updates.maximumActive == 1)

        // Failure retains last working cadence without retrying the same request.
        cadence.request(30)
        await drain()
        updates.finish(failing: true)
        await drain()
        precondition(cadence.appliedFramesPerSecond == 60 && cadence.desiredFramesPerSecond == 30 && cadence.state == .failed)
        cadence.request(30); cadence.request(30)
        await drain()
        precondition(updates.requested == [30, 60, 30])
        cadence.request(60)
        precondition(cadence.state == .idle)
        cadence.request(30)
        await drain()
        precondition(updates.requested == [30, 60, 30, 30])
        updates.finish()
        await drain()
        precondition(cadence.appliedFramesPerSecond == 30 && cadence.state == .idle)

        // Failed obsolete work must still converge to the latest request.
        cadence.request(60)
        await drain()
        cadence.request(30)
        updates.finish(failing: true)
        await drain()
        precondition(cadence.appliedFramesPerSecond == 30 && cadence.state == .idle)

        // Stop invalidates in-flight callbacks, including an updater that ignores cancellation.
        var oldNotifications = 0
        cadence.onStateChange = { oldNotifications += 1 }
        cadence.request(60)
        await drain()
        let beforeStop = oldNotifications
        cadence.stop(); cadence.stop()
        let freshUpdates = ControlledUpdates()
        let fresh = CaptureCadenceController(initialFramesPerSecond: 30, update: freshUpdates.update)
        fresh.request(60)
        await drain()
        updates.finish()
        await drain()
        precondition(oldNotifications == beforeStop && cadence.appliedFramesPerSecond == 30)
        precondition(fresh.state == .updating && fresh.appliedFramesPerSecond == 30)
        cadence.request(60)
        freshUpdates.finish()
        await drain()
        precondition(fresh.state == .idle && fresh.appliedFramesPerSecond == 60)

        // Independent display sessions: one failure cannot prevent another display updating.
        let secondUpdates = ControlledUpdates()
        let second = CaptureCadenceController(initialFramesPerSecond: 60, update: secondUpdates.update)
        fresh.request(30); second.request(30)
        await drain()
        freshUpdates.finish(failing: true)
        secondUpdates.finish()
        await drain()
        precondition(fresh.state == .failed && second.state == .idle)
        precondition(fresh.appliedFramesPerSecond == 60 && second.appliedFramesPerSecond == 30)
        second.request(24); second.request(0)
        precondition(second.desiredFramesPerSecond == 30)
        fresh.stop(); second.stop()
        print("PASS: Capture cadence coalescing, serialized latest-wins updates, failure retention and retry boundary, stop/restart isolation, and independent displays")
    }

    static func drain() async { for _ in 0..<30 { await Task.yield() } }
}
