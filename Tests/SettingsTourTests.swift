import Foundation

@main @MainActor struct SettingsTourTests {
    static func main() {
        let name = "AirVeil.TourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.2, forKey: "removalBrightnessV2")
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
        print("PASS: First launch, completion, skip, replay, navigation bounds, unique targets, and preference isolation")
    }
}
