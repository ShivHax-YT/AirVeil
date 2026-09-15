import Foundation
import Combine

enum EnergyMode: String, CaseIterable, Identifiable {
    case automatic
    case smoothest
    case reducedEnergy

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .smoothest: return "Smoothest"
        case .reducedEnergy: return "Reduced energy"
        }
    }
}

struct EnergySystemState {
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState

    static var current: EnergySystemState {
        EnergySystemState(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          thermalState: ProcessInfo.processInfo.thermalState)
    }
}

/// This policy changes desktop capture cadence only. Motion, coverage geometry,
/// camera checks, and presence detection keep their existing timing.
@MainActor final class EnergyController: ObservableObject {
    static let defaultsKey = "energyModeV1"
    @Published var mode: EnergyMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
            recompute()
        }
    }
    @Published private(set) var targetFramesPerSecond: Int = 60
    @Published private(set) var reason = "Automatic is using the usual desktop refresh."
    var onChange: ((Int) -> Void)?

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let systemStateProvider: () -> EnergySystemState
    private var systemState: EnergySystemState
    private var observers: [NSObjectProtocol] = []
    private var isShutdown = false

    init(defaults: UserDefaults = .standard, monitorSystem: Bool = true,
         notificationCenter: NotificationCenter = .default,
         systemStateProvider: @escaping () -> EnergySystemState = { .current }) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.systemStateProvider = systemStateProvider
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(EnergyMode.init(rawValue:)) ?? .automatic
        systemState = systemStateProvider()
        recompute()
        if monitorSystem {
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshSystemState() }
                })
            }
            // Close the gap between the initial read and observer registration.
            refreshSystemState()
        }
    }

    func reset() { mode = .automatic }

    func refresh() { refreshSystemState() }

    /// Also used by deterministic tests without changing the Mac's power state.
    func updateSystemState(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        guard !isShutdown else { return }
        systemState = EnergySystemState(lowPowerMode: lowPowerMode, thermalState: thermalState)
        recompute()
    }

    private func refreshSystemState() {
        guard !isShutdown else { return }
        let state = systemStateProvider()
        updateSystemState(lowPowerMode: state.lowPowerMode, thermalState: state.thermalState)
    }

    private func recompute() {
        guard !isShutdown else { return }
        let fps: Int
        let nextReason: String
        switch mode {
        case .smoothest:
            fps = 60
            nextReason = "Keeps the usual desktop refresh for smoother moving content."
        case .reducedEnergy:
            fps = 30
            nextReason = "Refreshes desktop content less often to reduce capture work."
        case .automatic:
            if systemState.lowPowerMode {
                fps = 30
                nextReason = "Refreshes desktop content less often while Low Power Mode is on."
            } else if systemState.thermalState == .serious || systemState.thermalState == .critical {
                fps = 30
                nextReason = "Refreshes desktop content less often while your Mac is running hot."
            } else {
                fps = 60
                nextReason = "Uses the usual desktop refresh under current conditions."
            }
        }
        if reason != nextReason { reason = nextReason }
        if targetFramesPerSecond != fps {
            targetFramesPerSecond = fps
            onChange?(fps)
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        onChange = nil
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }
}
