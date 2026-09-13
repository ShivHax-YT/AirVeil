import Foundation

@MainActor private final class FakeDisplaySleepRunner: DisplaySleepCommandRunning {
    struct Call { let executable:URL; let arguments:[String]; let timeout:TimeInterval }
    var calls:[Call] = []
    var result: Result<DisplaySleepCommandResult,Error>?
    var pending:[CheckedContinuation<DisplaySleepCommandResult,Error>] = []
    var cancelCount = 0
    var ignoreCancellation = false
    func run(executableURL:URL,arguments:[String],timeout:TimeInterval) async throws -> DisplaySleepCommandResult {
        calls.append(Call(executable:executableURL,arguments:arguments,timeout:timeout))
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func cancel() {
        cancelCount += 1
        if !ignoreCancellation, !pending.isEmpty { pending.removeFirst().resume(throwing:DisplaySleepError.cancelled) }
    }
    func completeFirst(_ result:Result<DisplaySleepCommandResult,Error>) { pending.removeFirst().resume(with:result) }
}

@main struct DisplaySleepServiceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition:Bool,_ message:String) { precondition(condition,message); checks += 1 }
        let success = DisplaySleepCommandResult(terminationStatus:0,standardError:"")
        let fake = FakeDisplaySleepRunner()
        let service = DisplaySleepService(runner:fake)
        fake.result = .success(success)
        try await service.requestDisplaySleep()
        check(fake.calls.count == 1,"A request launches exactly one injected command")
        check(fake.calls[0].executable.path == "/usr/bin/pmset","Fixed executable avoids shell lookup")
        check(fake.calls[0].arguments == ["displaysleepnow"],"Only documented display sleep argument")
        check(fake.calls[0].timeout == 3,"Completion has a three-second deadline")
        check(!service.isRunning,"Successful completion clears pending state")

        for failure in [DisplaySleepError.launchFailed("fixture launch failure"),.timedOut,.cancelled] {
            fake.result = .failure(failure)
            do { try await service.requestDisplaySleep(); preconditionFailure("Injected failure must surface") }
            catch let error as DisplaySleepError { check(error == failure,"Launch, timeout and cancellation remain distinguishable") }
            check(!service.isRunning,"Failure clears pending state")
        }
        fake.result = .success(DisplaySleepCommandResult(terminationStatus:17,standardError:"  fixture rejected request \n"))
        do { try await service.requestDisplaySleep(); preconditionFailure("Nonzero exit must fail") }
        catch let error as DisplaySleepError { check(error == .unsuccessfulExit(17,"fixture rejected request"),"Nonzero exit includes sanitized stderr") }
        fake.result = .success(DisplaySleepCommandResult(terminationStatus:1,standardError:String(repeating:"x",count:10000)))
        do { try await service.requestDisplaySleep(); preconditionFailure("Nonzero exit must fail") }
        catch DisplaySleepError.unsuccessfulExit(_,let detail) { check(detail.count == 4096,"Retained error text is bounded") }

        fake.result = nil
        let callsBefore = fake.calls.count
        let first = Task { try await service.requestDisplaySleep() }
        for _ in 0..<100 where fake.calls.count == callsBefore { await Task.yield() }
        check(service.isRunning && fake.pending.count == 1,"Pending request remains visible")
        do { try await service.requestDisplaySleep(); preconditionFailure("Concurrent request must be rejected") }
        catch let error as DisplaySleepError { check(error == .alreadyRunning,"Concurrent request has clear error") }
        check(fake.calls.count == callsBefore+1,"Concurrent request does not invoke command twice")
        service.cancel()
        check(!service.isRunning && fake.cancelCount == 1,"Shutdown cancellation clears state immediately and reaches runner")
        do { try await first.value; preconditionFailure("Cancelled request cannot report success") }
        catch let error as DisplaySleepError { check(error == .cancelled,"Cancelled task completes explicitly") }

        // A launched operation may finish after cancellation. Its old completion
        // must neither claim success nor clear a newer request's pending state.
        fake.ignoreCancellation = true
        let beforeOld = fake.calls.count
        let old = Task { try await service.requestDisplaySleep() }
        for _ in 0..<100 where fake.calls.count == beforeOld { await Task.yield() }
        check(fake.pending.count == 1,"Old request is waiting")
        service.cancel()
        let beforeNew = fake.calls.count
        let newer = Task { try await service.requestDisplaySleep() }
        for _ in 0..<100 where fake.calls.count == beforeNew { await Task.yield() }
        check(fake.pending.count == 2 && service.isRunning,"New request can begin after cancellation")
        fake.completeFirst(.success(success))
        do { try await old.value; preconditionFailure("Obsolete success must not publish") }
        catch let error as DisplaySleepError { check(error == .cancelled,"Late old completion becomes cancellation") }
        check(service.isRunning,"Obsolete cleanup cannot clear new pending request")
        fake.completeFirst(.success(success))
        try await newer.value
        check(!service.isRunning,"New request completes normally")
        check(fake.calls.allSatisfy { $0.executable.path == "/usr/bin/pmset" && $0.arguments == ["displaysleepnow"] },"Every test invocation stayed on fixed command contract")
        print("PASS: \(checks) display-sleep service assertions using injected runners only; no subprocess or display-sleep command executed")
    }
}
