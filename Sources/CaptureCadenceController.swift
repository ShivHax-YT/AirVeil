import Foundation

/// One instance per running stream. A newer request supersedes pending work,
/// while an in-flight update finishes before the next configuration is sent.
@MainActor final class CaptureCadenceController {
    enum State: Equatable {
        case idle
        case updating
        case failed
    }

    private(set) var desiredFramesPerSecond: Int
    private(set) var appliedFramesPerSecond: Int
    private(set) var state: State = .idle
    var onStateChange: (() -> Void)?

    private let update: (Int) async throws -> Void
    private var task: Task<Void, Never>?
    private var stopped = false

    init(initialFramesPerSecond: Int, update: @escaping (Int) async throws -> Void) {
        desiredFramesPerSecond = initialFramesPerSecond
        appliedFramesPerSecond = initialFramesPerSecond
        self.update = update
    }

    func request(_ framesPerSecond: Int) {
        guard !stopped, [30, 60].contains(framesPerSecond), desiredFramesPerSecond != framesPerSecond else { return }
        desiredFramesPerSecond = framesPerSecond
        guard task == nil else { return }
        if desiredFramesPerSecond == appliedFramesPerSecond {
            setState(.idle)
            return
        }
        task = Task { [weak self] in await self?.drain() }
        setState(.updating)
    }

    private func drain() async {
        while !stopped, desiredFramesPerSecond != appliedFramesPerSecond {
            let requested = desiredFramesPerSecond
            do {
                try await update(requested)
                guard !stopped else { return }
                appliedFramesPerSecond = requested
            } catch {
                guard !stopped else { return }
                // Do not retry this request or affect capture readiness. A newer
                // distinct request can still be applied after this failure.
                if desiredFramesPerSecond == requested {
                    task = nil
                    setState(.failed)
                    return
                }
            }
        }
        guard !stopped else { return }
        task = nil
        setState(.idle)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        task = nil
        state = .idle
        onStateChange = nil
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?()
    }
}
