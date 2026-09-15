import SwiftUI

/// Production entry surface: permission choices come before the first tour.
struct AirVeilSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tour: SettingsTour
    @ObservedObject var onboarding: PermissionOnboarding
    var onBackgroundAnimationTick: ((TimeInterval) -> Void)? = nil
    var body: some View {
        Group {
            if onboarding.isActive {
                PermissionOnboardingView(onboarding: onboarding, onBackgroundAnimationTick: onBackgroundAnimationTick)
            } else {
                SettingsView(model: model, tour: tour, showPermissions: { onboarding.replay() })
            }
        }
    }
}
