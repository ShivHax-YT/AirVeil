import Foundation
import Darwin

enum DisplaySleepError: LocalizedError, Equatable {
    case alreadyRunning
    case launchFailed(String)
    case unsuccessfulExit(Int32, String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A display sleep request is already pending."
        case .launchFailed(let detail): return "Could not request display sleep: \(detail)"
        case .unsuccessfulExit(let code, let detail):
            return detail.isEmpty ? "Display sleep request failed (exit \(code))." : "Display sleep request failed (exit \(code)): \(detail)"
        case .timedOut: return "The display sleep request timed out."
        case .cancelled: return "The pending display sleep request was cancelled."
        }
    }
}

struct DisplaySleepCommandResult {
    let terminationStatus: Int32
    let standardError: String
}

@MainActor protocol DisplaySleepCommandRunning: AnyObject {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> DisplaySleepCommandResult
    func cancel()
}

/// Requests display sleep using the documented system command. A successful
/// request does not prove password locking; the Mac's Lock Screen policy applies.
@MainActor final class DisplaySleepService {
    private(set) var isRunning = false
    private var generation: UInt64 = 0
    private let runner: any DisplaySleepCommandRunning

    convenience init() { self.init(runner: SystemDisplaySleepCommandRunner()) }
    init(runner: any DisplaySleepCommandRunning) { self.runner = runner }

    func requestDisplaySleep() async throws {
        guard !isRunning else { throw DisplaySleepError.alreadyRunning }
        generation &+= 1
        let request = generation
        isRunning = true
        defer { if request == generation { isRunning = false } }
        let result = try await runner.run(executableURL: URL(fileURLWithPath:"/usr/bin/pmset"),
                                          arguments:["displaysleepnow"], timeout:3)
        guard request == generation, !Task.isCancelled else { throw DisplaySleepError.cancelled }
        guard result.terminationStatus == 0 else {
            let detail = String(result.standardError.prefix(4096)).trimmingCharacters(in:.whitespacesAndNewlines)
            throw DisplaySleepError.unsuccessfulExit(result.terminationStatus, detail)
        }
    }

    /// Cancels waiting/processing, but cannot undo display sleep already requested
    /// by a subprocess that has begun executing.
    func cancel() {
        generation &+= 1
        isRunning = false
        runner.cancel()
    }
}

private final class BoundedDisplaySleepErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func drain(_ descriptor: Int32) {
        lock.lock(); defer { lock.unlock() }
        var chunk = [UInt8](repeating:0,count:4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor,$0.baseAddress,4096) }
            if count <= 0 { break }
            if bytes.count < 4096 { bytes.append(contentsOf:chunk.prefix(min(count,4096-bytes.count))) }
        }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding:bytes,as:UTF8.self)
    }
}

@MainActor private final class SystemDisplaySleepCommandRunner: DisplaySleepCommandRunning {
    private final class Operation {
        let id: UUID
        let process: Process
        let errorPipe: Pipe
        let errors: BoundedDisplaySleepErrorBuffer
        let continuation: CheckedContinuation<DisplaySleepCommandResult, Error>
        var timeoutTask: Task<Void,Never>?
        init(id:UUID,process:Process,errorPipe:Pipe,errors:BoundedDisplaySleepErrorBuffer,
             continuation:CheckedContinuation<DisplaySleepCommandResult,Error>) {
            self.id = id; self.process = process; self.errorPipe = errorPipe
            self.errors = errors; self.continuation = continuation
        }
    }
    private var active: Operation?

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> DisplaySleepCommandResult {
        guard active == nil else { throw DisplaySleepError.alreadyRunning }
        guard !Task.isCancelled else { throw DisplaySleepError.cancelled }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process(), pipe = Pipe(), errors = BoundedDisplaySleepErrorBuffer()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = pipe
                // Drain stderr continuously even after the retained prefix fills,
                // so a noisy child cannot block waiting for pipe capacity.
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                let flags = fcntl(descriptor,F_GETFL)
                guard flags >= 0, fcntl(descriptor,F_SETFL,flags | O_NONBLOCK) == 0 else {
                    continuation.resume(throwing:DisplaySleepError.launchFailed("Could not configure the command output pipe."))
                    return
                }
                pipe.fileHandleForReading.readabilityHandler = { handle in errors.drain(handle.fileDescriptor) }
                let operation = Operation(id:id,process:process,errorPipe:pipe,errors:errors,continuation:continuation)
                active = operation
                process.terminationHandler = { [weak self] finished in
                    // Drain the final bytes without waiting for EOF. A lock in the
                    // collector serializes this with any pending readability callback.
                    pipe.fileHandleForReading.readabilityHandler = nil
                    errors.drain(pipe.fileHandleForReading.fileDescriptor)
                    let status = finished.terminationStatus
                    Task { @MainActor [weak self] in self?.completed(id:id,status:status) }
                }
                do { try process.run() }
                catch { finish(id:id,result:.failure(DisplaySleepError.launchFailed(error.localizedDescription)),terminate:false); return }
                let seconds = timeout.isFinite ? min(10,max(0.1,timeout)) : 3
                operation.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
                    catch { return }
                    self?.finish(id:id,result:.failure(DisplaySleepError.timedOut),terminate:true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id:id,result:.failure(DisplaySleepError.cancelled),terminate:true) }
        }
    }

    func cancel() {
        guard let id = active?.id else { return }
        finish(id:id,result:.failure(DisplaySleepError.cancelled),terminate:true)
    }
    private func completed(id: UUID, status: Int32) {
        guard let operation = active, operation.id == id else { return }
        finish(id:id,result:.success(DisplaySleepCommandResult(terminationStatus:status,standardError:operation.errors.text)),terminate:false)
    }
    private func finish(id:UUID,result:Result<DisplaySleepCommandResult,Error>,terminate:Bool) {
        guard let operation = active, operation.id == id else { return }
        active = nil
        operation.timeoutTask?.cancel()
        operation.errorPipe.fileHandleForReading.readabilityHandler = nil
        if terminate, operation.process.isRunning {
            operation.process.terminate()
            let process = operation.process
            Task {
                try? await Task.sleep(nanoseconds:300_000_000)
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            }
        }
        operation.continuation.resume(with:result)
    }
}
