import Foundation

@MainActor final class TestPermissionProvider: PermissionOnboardingProviding {
    var states = Dictionary(uniqueKeysWithValues: AirVeilPermission.allCases.map { ($0, PermissionAccessSnapshot(.notDetermined)) })
    var requests: [AirVeilPermission] = []
    var settings: [AirVeilPermission] = []
    var cancelCount = 0
    var pending: CheckedContinuation<PermissionAccessSnapshot, Never>?
    var suspendRequest = false
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot { states[permission]! }
    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot {
        requests.append(permission)
        if suspendRequest { return await withCheckedContinuation { pending = $0 } }
        return states[permission]!
    }
    func openSettings(for permission: AirVeilPermission) { settings.append(permission) }
    func cancelPendingRequest() { cancelCount += 1 }
}

@main @MainActor struct PermissionOnboardingTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); assertions += 1
    }
    static func main() async {
        let suite = "AirVeil.PermissionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.27, forKey: "removalBrightnessV2")
        let provider = TestPermissionProvider()
        let setup = PermissionOnboarding(defaults: defaults, provider: provider)
        check(setup.isActive && setup.phase == .welcome, "Fresh users must see permission setup")
        check(provider.requests.isEmpty, "Reading OS state must not request access")
        setup.finish()
        check(setup.isActive, "Welcome cannot silently complete")
        setup.begin()
        check(setup.currentPermission == .camera, "Camera is first")
        setup.markReviewed(.screenRecording)
        check(setup.reviewed.isEmpty, "Offscreen future cards cannot unlock consent")
        await setup.requestCurrentPermission()
        setup.continueWithAccess(); setup.openCurrentSettings()
        check(provider.requests.isEmpty && provider.settings.isEmpty && setup.currentPermission == .camera, "Unreviewed card cannot request, grant, or open Settings via primary action")
        setup.continueWithoutAccess()
        check(setup.currentPermission == .screenRecording && setup.choices[.camera] == .notNow, "Decline remains immediately available")
        let resumed = PermissionOnboarding(defaults: defaults, provider: provider)
        check(resumed.phase == .permission(.screenRecording) && resumed.choices[.camera] == .notNow, "An incomplete decline persists across relaunch")
        setup.continueWithoutAccess(); setup.continueWithoutAccess()
        check(setup.phase == .summary && setup.reviewed.isEmpty, "All permissions can be declined without a reading trap")
        var finished = 0; setup.onFinish = { finished += 1 }
        setup.finish(); setup.finish()
        check(!setup.isActive && finished == 1, "Finish fires once after all choices")
        check(!setup.cameraChoiceAllowsAssistance && !setup.headTrackingChoiceAllowsMotion, "Skipped sensors stay disabled")
        check(!PermissionOnboarding(defaults: defaults, provider: provider).isActive, "Completed setup stays completed")
        var began = 0; setup.onBegin = { began += 1 }
        setup.replay()
        check(began == 1 && setup.isActive && setup.choices.isEmpty && setup.reviewed.isEmpty, "Replay gates runtime and resets choices")
        setup.begin(); setup.markReviewed(.camera)
        await setup.requestCurrentPermission()
        check(provider.requests == [.camera] && setup.status(for: .camera).authorization == .notDetermined, "Clicking Allow is not proof of OS authorization")
        setup.continueWithAccess()
        check(setup.currentPermission == .camera, "An unresolved OS prompt cannot advance as allowed")
        provider.states[.camera] = PermissionAccessSnapshot(.denied)
        await setup.requestCurrentPermission(); setup.continueWithAccess(); setup.openCurrentSettings()
        check(setup.currentPermission == .camera && provider.settings == [.camera], "Denial remains honest and offers Settings")
        provider.states[.camera] = PermissionAccessSnapshot(.authorized); setup.refresh(); setup.continueWithAccess()
        check(setup.cameraChoiceAllowsAssistance && setup.currentPermission == .screenRecording, "Verified camera choice may enable assistance only after continuation")
        provider.states[.screenRecording] = PermissionAccessSnapshot(.authorized); setup.refresh()
        setup.continueWithAccess()
        check(setup.currentPermission == .screenRecording, "A preexisting OS grant still requires this card to be reviewed")
        setup.markReviewed(.screenRecording); setup.continueWithAccess()
        provider.states[.headTracking] = PermissionAccessSnapshot(.authorized); setup.refresh(); setup.markReviewed(.headTracking); setup.continueWithAccess()
        check(setup.phase == .summary && setup.headTrackingChoiceAllowsMotion, "Exactly three reviewed choices reach summary")
        provider.states[.headTracking] = PermissionAccessSnapshot(.denied)
        setup.finish()
        check(!setup.headTrackingChoiceAllowsMotion, "Finish rechecks OS permission revoked since card was accepted")
        setup.replay(); setup.begin(); setup.markReviewed(.camera)
        provider.suspendRequest = true
        let request = Task { await setup.requestCurrentPermission() }
        while provider.pending == nil { await Task.yield() }
        check(setup.isRequesting, "Outstanding system request is visible")
        setup.continueWithoutAccess(); setup.back()
        check(setup.currentPermission == .camera, "Navigation cannot leave an outstanding permission request")
        setup.replay()
        provider.pending?.resume(returning: PermissionAccessSnapshot(.authorized)); provider.pending = nil
        await request.value
        check(setup.phase == .welcome && !setup.isRequesting && setup.choices.isEmpty, "A stale callback cannot accept permission after replay")
        check(provider.cancelCount >= 3, "Replay cancels the temporary request transport")
        check(defaults.double(forKey: "removalBrightnessV2") == 0.27, "Permission setup does not change physical display preferences")
        check(AirVeilPermission.allCases == [.camera, .screenRecording, .headTracking], "Bluetooth is not required")
        for permission in AirVeilPermission.allCases {
            check(!permission.skipTitle.isEmpty && !permission.skipConsequence.isEmpty && permission.sections.count >= 4, "Every permission explains its use, privacy, and optional consequence")
        }
        print("PASS: \(assertions) permission onboarding checks; fake provider only, no camera, screen capture, motion, or OS prompts")
    }
}
