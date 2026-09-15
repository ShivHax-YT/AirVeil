import Foundation
import Combine

enum AirVeilPermission: String, CaseIterable, Identifiable, Codable {
    case camera, screenRecording, headTracking
    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return "Camera"
        case .screenRecording: return "Screen Recording"
        case .headTracking: return "Head Tracking"
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "camera"
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .headTracking: return "airpodspro"
        }
    }
    var subtitle: String {
        switch self {
        case .camera: return "Find your screen. Recognize an empty seat."
        case .screenRecording: return "Blur the desktop you are actually using."
        case .headTracking: return "Let your AirPods follow your attention."
        }
    }
    var allowTitle: String {
        switch self {
        case .camera: return "Allow camera access"
        case .screenRecording: return "Allow screen recording"
        case .headTracking: return "Allow head tracking"
        }
    }
    var skipTitle: String {
        switch self {
        case .camera: return "Continue without camera"
        case .screenRecording: return "Continue with preview only"
        case .headTracking: return "Continue without head tracking"
        }
    }
    var skipConsequence: String {
        switch self {
        case .camera: return "Without camera access, you can still set your center manually. Camera alignment and seat checks stay off."
        case .screenRecording: return "Without this access, live desktop blur stays off. You can still explore the simulated preview."
        case .headTracking: return "Without Motion & Fitness access, head-controlled blur stays off. The simulated preview still works."
        }
    }
    var sections: [(title: String, detail: String)] {
        switch self {
        case .camera:
            return [
                ("Why AirVeil asks", "The built-in camera helps match your AirPods to your screen and check whether you are still at your desk. It is optional: manual Set center does not need camera access."),
                ("When it is used", "AirVeil uses brief camera checks for alignment. If you choose automatic display management, it can also check your seat after both AirPods are removed and their motion stream stops. The camera indicator shows when it is active."),
                ("What stays private", "Camera images are processed on this Mac and discarded. AirVeil does not save recordings, identify you by name, or send camera images to a server. Saved screen direction is numeric; the seat reference stays in memory for this session."),
                ("Your choice", "Allowing access here gives macOS permission for these features. It does not start a camera check during setup. You can turn camera assistance off later in AirVeil or revoke access in System Settings.")
            ]
        case .screenRecording:
            return [
                ("Why AirVeil asks", "Live blur needs the current image of your selected displays. macOS calls this Screen Recording, even though AirVeil uses the frames to draw an effect rather than save a recording."),
                ("When it is used", "Desktop capture begins only when you choose Enable blur. Pausing the effect stops capture and releases captured pixels. You choose which displays receive the effect."),
                ("What stays private", "Captured frames are processed on this Mac. AirVeil does not record a video, upload desktop images, or use them to train a model. It does not request microphone access for this effect."),
                ("Your choice", "This setup checks access without starting a live desktop effect. macOS may ask you to reopen AirVeil after changing permission. You can return here to check again, or continue with the simulated preview.")
            ]
        case .headTracking:
            return [
                ("Why AirVeil asks", "Compatible AirPods provide head-motion measurements so the screen can respond when you turn away. macOS places this permission under Motion & Fitness."),
                ("When it is used", "The permission request may briefly start a motion session with connected AirPods, then stop it. After setup, you explicitly start tracking in the tour or finish the tour to begin. No microphone or audio recording is needed."),
                ("What stays private", "AirVeil uses the direction and timing of motion samples on this Mac. It does not upload them or use Bluetooth device metadata to identify you. Tracking can pause when AirPods disconnect or macOS stops their motion stream."),
                ("Your choice", "Connect and wear compatible AirPods before allowing access. If macOS does not offer a prompt yet, connect them and try again. You can revoke Motion & Fitness access in System Settings or continue with a simulated preview.")
            ]
        }
    }
}

enum PermissionAuthorization: String, Codable {
    case notDetermined, notGranted, authorized, denied, restricted, unavailable
    var title: String {
        switch self {
        case .notDetermined: return "Not requested yet"
        case .notGranted: return "Access is not verified"
        case .authorized: return "Access allowed"
        case .denied: return "Access not allowed"
        case .restricted: return "Restricted by this Mac"
        case .unavailable: return "Connect compatible AirPods"
        }
    }
    var allowsAccess: Bool { self == .authorized }
}

struct PermissionAccessSnapshot: Equatable {
    var authorization: PermissionAuthorization
    var message: String?
    init(_ authorization: PermissionAuthorization, message: String? = nil) {
        self.authorization = authorization; self.message = message
    }
}

@MainActor protocol PermissionOnboardingProviding: AnyObject {
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot
    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot
    func openSettings(for permission: AirVeilPermission)
    func cancelPendingRequest()
}

enum PermissionChoice: String, Codable { case allowed, notNow }
enum PermissionOnboardingPhase: Equatable {
    case welcome, permission(AirVeilPermission), summary
}

/// Setup records informed choices, while macOS remains the authority on access.
/// Reading a card, clicking Allow, or finishing setup never fabricates a grant.
@MainActor final class PermissionOnboarding: ObservableObject {
    static let completionKey = "permissionOnboardingCompletedV1"
    private static let phaseKey = "permissionOnboardingPhaseV1"
    private static let readKey = "permissionOnboardingReadV1"
    private static let choicesKey = "permissionOnboardingChoicesV1"
    @Published private(set) var phase: PermissionOnboardingPhase = .welcome
    @Published private(set) var isActive: Bool
    @Published private(set) var statuses: [AirVeilPermission: PermissionAccessSnapshot] = [:]
    @Published private(set) var reviewed: Set<AirVeilPermission> = []
    @Published private(set) var choices: [AirVeilPermission: PermissionChoice] = [:]
    @Published private(set) var requestingPermission: AirVeilPermission?
    var onBegin: (() -> Void)?
    var onFinish: (() -> Void)?
    private let defaults: UserDefaults
    private let provider: any PermissionOnboardingProviding
    private var requestGeneration = 0

    init(defaults: UserDefaults = .standard, provider: any PermissionOnboardingProviding) {
        self.defaults = defaults; self.provider = provider
        isActive = !defaults.bool(forKey: Self.completionKey)
        reviewed = Set((defaults.stringArray(forKey: Self.readKey) ?? []).compactMap(AirVeilPermission.init(rawValue:)))
        for (raw, value) in defaults.dictionary(forKey: Self.choicesKey) ?? [:] {
            if let permission = AirVeilPermission(rawValue: raw), let rawChoice = value as? String,
               let choice = PermissionChoice(rawValue: rawChoice), choice == .notNow || reviewed.contains(permission) {
                choices[permission] = choice
            }
        }
        if let saved = defaults.string(forKey: Self.phaseKey) {
            if saved == "summary", choices.count == AirVeilPermission.allCases.count { phase = .summary }
            else if let permission = AirVeilPermission(rawValue: saved) { phase = .permission(permission) }
        }
        // An interrupted or older partial record resumes at its first undecided card.
        if case .permission(let permission) = phase,
           let missing = AirVeilPermission.allCases.prefix(while: { $0 != permission }).first(where: { choices[$0] == nil }) {
            phase = .permission(missing)
        }
        refresh()
    }

    var currentPermission: AirVeilPermission? {
        if case .permission(let permission) = phase { return permission }
        return nil
    }
    var currentIndex: Int? { currentPermission.flatMap { AirVeilPermission.allCases.firstIndex(of: $0) } }
    var isRequesting: Bool { requestingPermission != nil }
    var hasReviewedCurrent: Bool { currentPermission.map { reviewed.contains($0) } ?? false }
    var cameraChoiceAllowsAssistance: Bool {
        choices[.camera] == .allowed && status(for: .camera).authorization.allowsAccess
    }
    var headTrackingChoiceAllowsMotion: Bool {
        choices[.headTracking] == .allowed && status(for: .headTracking).authorization.allowsAccess
    }
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot {
        statuses[permission] ?? PermissionAccessSnapshot(.notDetermined)
    }
    func refresh() {
        for permission in AirVeilPermission.allCases { statuses[permission] = provider.status(for: permission) }
    }
    func begin() {
        guard isActive, phase == .welcome else { return }
        phase = .permission(AirVeilPermission.allCases[0]); persist()
    }
    func replay() {
        cancelPendingRequest()
        onBegin?()
        reviewed = []; choices = [:]; phase = .welcome
        defaults.set(false, forKey: Self.completionKey)
        isActive = true; refresh(); persist()
    }
    /// Called only when the final paragraph is actually visible in its scroll view.
    func markReviewed(_ permission: AirVeilPermission) {
        guard isActive, currentPermission == permission else { return }
        if reviewed.insert(permission).inserted { persist() }
    }
    func requestCurrentPermission() async {
        guard isActive, let permission = currentPermission, reviewed.contains(permission), !isRequesting else { return }
        requestingPermission = permission; requestGeneration += 1
        let generation = requestGeneration
        let result = await provider.request(permission)
        guard generation == requestGeneration, currentPermission == permission, isActive else { return }
        statuses[permission] = result
        requestingPermission = nil
    }
    func openCurrentSettings() {
        guard let permission = currentPermission, reviewed.contains(permission), !isRequesting else { return }
        provider.openSettings(for: permission)
    }
    func continueWithAccess() {
        guard isActive, let permission = currentPermission, reviewed.contains(permission), !isRequesting,
              status(for: permission).authorization.allowsAccess else { return }
        choices[permission] = .allowed; advance(after: permission)
    }
    func continueWithoutAccess() {
        guard isActive, let permission = currentPermission, !isRequesting else { return }
        choices[permission] = .notNow; advance(after: permission)
    }
    func back() {
        guard isActive, !isRequesting else { return }
        switch phase {
        case .welcome: return
        case .permission(let permission):
            let index = AirVeilPermission.allCases.firstIndex(of: permission)!
            phase = index == 0 ? .welcome : .permission(AirVeilPermission.allCases[index - 1])
        case .summary: phase = .permission(AirVeilPermission.allCases.last!)
        }
        refresh(); persist()
    }
    func finish() {
        guard isActive, phase == .summary, choices.count == AirVeilPermission.allCases.count,
              choices.allSatisfy({ $0.value == .notNow || reviewed.contains($0.key) }), !isRequesting else { return }
        refresh()
        defaults.set(true, forKey: Self.completionKey)
        isActive = false; onFinish?()
    }
    func cancelPendingRequest() {
        requestGeneration += 1; provider.cancelPendingRequest(); requestingPermission = nil
    }
    private func advance(after permission: AirVeilPermission) {
        let index = AirVeilPermission.allCases.firstIndex(of: permission)!
        phase = index + 1 < AirVeilPermission.allCases.count ? .permission(AirVeilPermission.allCases[index + 1]) : .summary
        persist()
    }
    private func persist() {
        let savedPhase: String
        switch phase {
        case .welcome: savedPhase = "welcome"
        case .permission(let permission): savedPhase = permission.rawValue
        case .summary: savedPhase = "summary"
        }
        defaults.set(savedPhase, forKey: Self.phaseKey)
        defaults.set(reviewed.map(\.rawValue), forKey: Self.readKey)
        defaults.set(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: Self.choicesKey)
    }
}
