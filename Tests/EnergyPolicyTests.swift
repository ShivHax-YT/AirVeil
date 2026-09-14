import Foundation

@main @MainActor struct EnergyPolicyTests {
    static func main() async {
        let suite = "AirVeil.EnergyPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let normal = { EnergySystemState(lowPowerMode: false, thermalState: .nominal) }
        let energy = EnergyController(defaults: defaults, monitorSystem: false, systemStateProvider: normal)
        precondition(energy.mode == .automatic && energy.targetFramesPerSecond == 60)
        precondition(defaults.object(forKey: EnergyController.defaultsKey) == nil, "Startup must not persist a preference")
        var callbacks: [Int] = []
        energy.onChange = { callbacks.append($0) }
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                energy.updateSystemState(lowPowerMode: lowPower, thermalState: thermal)
                let expected = lowPower || thermal == .serious || thermal == .critical ? 30 : 60
                precondition(energy.targetFramesPerSecond == expected)
                precondition(!energy.reason.isEmpty)
            }
        }
        energy.updateSystemState(lowPowerMode: false, thermalState: ProcessInfo.ThermalState(rawValue: 99)!)
        precondition(energy.targetFramesPerSecond == 60, "Unknown future thermal states retain the standard cadence")
        energy.updateSystemState(lowPowerMode: true, thermalState: .critical)
        let beforeDuplicate = callbacks.count
        energy.updateSystemState(lowPowerMode: true, thermalState: .critical)
        precondition(callbacks.count == beforeDuplicate, "Duplicate system notifications must not resubmit capture updates")
        precondition(defaults.object(forKey: EnergyController.defaultsKey) == nil, "System adaptation must not overwrite preferences")
        energy.mode = .smoothest
        precondition(energy.targetFramesPerSecond == 60)
        energy.updateSystemState(lowPowerMode: true, thermalState: .critical)
        precondition(energy.targetFramesPerSecond == 60)
        energy.mode = .reducedEnergy
        energy.updateSystemState(lowPowerMode: false, thermalState: .nominal)
        precondition(energy.targetFramesPerSecond == 30)
        precondition(defaults.string(forKey: EnergyController.defaultsKey) == EnergyMode.reducedEnergy.rawValue)
        let restored = EnergyController(defaults: defaults, monitorSystem: false, systemStateProvider: normal)
        precondition(restored.mode == .reducedEnergy && restored.targetFramesPerSecond == 30)
        restored.shutdown()
        energy.reset()
        precondition(energy.mode == .automatic && energy.targetFramesPerSecond == 60)
        energy.shutdown(); energy.shutdown()
        energy.updateSystemState(lowPowerMode: true, thermalState: .critical)
        precondition(energy.targetFramesPerSecond == 60)

        defaults.set("future-mode", forKey: EnergyController.defaultsKey)
        let unknown = EnergyController(defaults: defaults, monitorSystem: false, systemStateProvider: normal)
        precondition(unknown.mode == .automatic)
        precondition(defaults.string(forKey: EnergyController.defaultsKey) == "future-mode", "Unknown stored values must not be rewritten at startup")
        unknown.shutdown()
        defaults.removeObject(forKey: EnergyController.defaultsKey)

        let center = NotificationCenter()
        var state = EnergySystemState(lowPowerMode: true, thermalState: .nominal)
        var reads = 0
        let observed = EnergyController(defaults: defaults, notificationCenter: center, systemStateProvider: {
            reads += 1
            return state
        })
        precondition(observed.targetFramesPerSecond == 30, "Read current power before first notification")
        state = EnergySystemState(lowPowerMode: false, thermalState: .nominal)
        // Real observer path accepts a notification arriving off the main thread.
        await Task.detached {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }.value
        await drain()
        precondition(observed.targetFramesPerSecond == 60)
        state = EnergySystemState(lowPowerMode: false, thermalState: .serious)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drain()
        precondition(observed.targetFramesPerSecond == 30)
        state = EnergySystemState(lowPowerMode: false, thermalState: .nominal)
        observed.refresh()
        precondition(observed.targetFramesPerSecond == 60, "Wake refresh rereads system state without relying on a notification")
        state = EnergySystemState(lowPowerMode: true, thermalState: .nominal)
        observed.refresh()
        let lastReads = reads
        // A queued callback must not revive a shut-down owner.
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        observed.shutdown(); observed.shutdown()
        state = EnergySystemState(lowPowerMode: false, thermalState: .nominal)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await drain()
        precondition(reads == lastReads && observed.targetFramesPerSecond == 30)
        print("PASS: Energy policy matrix, persistence, fallback, reset, initial system read, background notifications, and idempotent observer shutdown")
    }

    static func drain() async { for _ in 0..<20 { await Task.yield() } }
}
