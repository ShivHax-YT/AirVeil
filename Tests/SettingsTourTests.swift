import Foundation

@main @MainActor struct SettingsTourTests {
    static func main() {
        let name = "AirVeil.TourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.2, forKey: "removalBrightnessV2")
        let deferred = SettingsTour(defaults: defaults, startImmediately: false)
        var prematureFinishes = 0
        deferred.onFinish = { prematureFinishes += 1 }
        precondition(!deferred.isActive)
        deferred.finish(); deferred.next()
        precondition(prematureFinishes == 0 && !defaults.bool(forKey: SettingsTour.completionKey))
        deferred.beginIfNeeded()
        precondition(deferred.step == .welcome)
        deferred.suspendForPermissions()
        precondition(!deferred.isActive && prematureFinishes == 0 && !defaults.bool(forKey: SettingsTour.completionKey))
        deferred.beginIfNeeded()
        precondition(deferred.step == .welcome)
        let tour = SettingsTour(defaults: defaults)
        precondition(tour.step == .welcome)
        tour.back()
        precondition(tour.step == .welcome)
        var finishes = 0
        tour.onFinish = { finishes += 1 }
        for step in SettingsTourStep.allCases {
            precondition(tour.step == step && !step.title.isEmpty && !step.detail.isEmpty)
            tour.next()
        }
        precondition(!tour.isActive && finishes == 1)
        precondition(!SettingsTour(defaults: defaults).isActive)
        tour.finish(); tour.next()
        precondition(finishes == 1)
        tour.replay(); tour.next(); tour.back()
        precondition(tour.step == .welcome)
        tour.finish()
        precondition(!tour.isActive && finishes == 2)
        precondition(defaults.double(forKey: "removalBrightnessV2") == 0.2)
        precondition(Set(SettingsTourStep.allCases.map(\.id)).count == SettingsTourStep.allCases.count)
        let expectedSections: [(SettingsSection, [SettingsTourStep])] = [
            (.preview, [.welcome, .preview, .ready]),
            (.tracking, [.tracking, .camera]),
            (.displays, [.access, .displays, .input]),
            (.appearance, [.coverage, .onset, .full, .appearance, .tuning]),
            (.power, [.removal, .seated, .energy])
        ]
        precondition(expectedSections.count == SettingsSection.allCases.count)
        precondition(expectedSections.flatMap(\.1).count == SettingsTourStep.allCases.count)
        for (section, steps) in expectedSections {
            precondition(!section.symbol.isEmpty)
            for step in steps { precondition(step.section == section, "Every tour target must route to its real tab") }
        }
        tour.replay()
        for next in SettingsTourStep.allCases.dropFirst() {
            tour.next()
            precondition(tour.step == next)
            tour.back()
            precondition(tour.step != next)
            tour.next()
            precondition(tour.step?.section == next.section)
        }
        precondition(defaults.double(forKey: "removalBrightnessV2") == 0.2)
        print("PASS: Permission-first launch, suspension, completion, replay, all 16 forward/back tab destinations, unique targets, and preference isolation")
    }
}
