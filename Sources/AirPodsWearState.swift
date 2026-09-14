import Foundation
import IOBluetooth
import ObjectiveC

/// Two anonymous in-ear bits from one compatible, connected headset. The token
/// only distinguishes device replacement within this process; it is not saved.
struct AirPodsWearReading: Equatable, Sendable {
    let deviceToken: String
    let wornMask: UInt8
    let receipt: TimeInterval
    var isValid: Bool {
        !deviceToken.isEmpty && wornMask <= 3 && receipt.isFinite && receipt >= 0
    }
}

enum AirPodsWearTransition { case unchanged, removed, reworn }

/// Source selection is not ear detection. Only stable per-bud metadata changes
/// can establish removal independently of Core Motion connection events. Unknown metadata
/// never fabricates a removal, and never clears an already observed removal.
struct AirPodsWearEvidence {
    private(set) var isRemovalLatched = false
    private(set) var hasCurrentMetadata = false
    var wornMask: UInt8? { accepted?.wornMask }
    private var accepted: AirPodsWearReading?
    private var candidate: AirPodsWearReading?
    private var candidateCount = 0
    private var latestReceipt: TimeInterval?

    mutating func reset() { self = AirPodsWearEvidence() }

    mutating func noteExplicitReconnect() {
        // A Bluetooth reconnect may happen with one AirPod still out. Preserve
        // positive per-bud removal evidence until an actual worn-mask increase
        // or the user's explicit recovery action; transport alone is weaker.
        if !isRemovalLatched { accepted = nil }
        candidate = nil; candidateCount = 0
        hasCurrentMetadata = false; latestReceipt = nil
    }

    mutating func update(_ reading: AirPodsWearReading?, freshMotion: Bool,
                         now: TimeInterval) -> AirPodsWearTransition {
        guard now.isFinite, let reading, reading.isValid,
              now >= reading.receipt, now - reading.receipt <= 0.75 else {
            candidate = nil; candidateCount = 0; hasCurrentMetadata = false
            return .unchanged
        }
        // A background framework query can take longer than the polling tick.
        // Seeing its still-fresh cached result again is not a new observation
        // and must not erase the preceding candidate's stability evidence.
        if let latestReceipt, reading.receipt <= latestReceipt { return .unchanged }
        latestReceipt = reading.receipt
        hasCurrentMetadata = true
        if let accepted, accepted.deviceToken != reading.deviceToken {
            // Another headset cannot prove that the removed AirPod returned.
            guard !isRemovalLatched else { hasCurrentMetadata = false; return .unchanged }
            self.accepted = nil; candidate = nil; candidateCount = 0
        }
        if candidate?.deviceToken != reading.deviceToken || candidate?.wornMask != reading.wornMask {
            candidate = reading; candidateCount = 1
            return .unchanged
        }
        candidateCount += 1
        guard let candidate, candidateCount >= 2, reading.receipt - candidate.receipt >= 0.2 else { return .unchanged }
        guard let previous = accepted else {
            // A first "out" snapshot is not an observed removal. Establish the
            // wear baseline only alongside usable motion from a worn headset.
            guard freshMotion, reading.wornMask != 0, !isRemovalLatched else { return .unchanged }
            accepted = reading
            return .unchanged
        }
        accepted = reading
        let gained = reading.wornMask & ~previous.wornMask
        let lost = previous.wornMask & ~reading.wornMask
        if isRemovalLatched, gained != 0 {
            isRemovalLatched = false
            return .reworn
        }
        if !isRemovalLatched, lost != 0 {
            isRemovalLatched = true
            return .removed
        }
        return .unchanged
    }
}

/// Compatibility supplement used by established macOS tools such as
/// Hammerspoon. These IOBluetooth getters are PRIVATE, runtime/type checked,
/// read-only, and never used to connect, pair, scan, or change ear detection.
/// Unsupported, disabled, ambiguous, and unknown values return no evidence.
@MainActor final class SystemAirPodsWearReader {
    private(set) var diagnosticStatus = "Individual-AirPod metadata has not been queried."
    private let queue = DispatchQueue(label: "AirVeil.IndividualAirPods", qos: .utility)
    private let worker = BluetoothWearWorker()
    private var reading: AirPodsWearReading?
    private var pending = false

    func read(now: TimeInterval) -> AirPodsWearReading? {
        guard now.isFinite, now >= 0 else { return nil }
        if !pending {
            pending = true
            queue.async { [worker, weak self] in
                let result = worker.read()
                let detail = worker.diagnosticStatus
                Task { @MainActor [weak self] in
                    self?.reading = result
                    self?.diagnosticStatus = detail
                    self?.pending = false
                }
            }
        }
        return reading
    }
}

/// Framework IPC and initialization run on one utility queue, never the UI or
/// sensor acquisition queue. A slow query stays one in-flight operation and
/// stale cached evidence expires instead of blocking animations/head tracking.
private final class BluetoothWearWorker: @unchecked Sendable {
    private(set) var diagnosticStatus = "Bluetooth metadata has not been queried."
    private var selected: IOBluetoothDevice?
    private var token = UUID().uuidString

    func read() -> AirPodsWearReading? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            diagnosticStatus = "Paired-device enumeration is unavailable."
            return nil
        }
        let connected = devices.filter { $0.isConnected() }
        let supported = devices.filter { byte($0, "isAppleDevice") == 1 && byte($0, "isInEarDetectionSupported") == 1 }
        let fields = supported.map { device in
            let value: (String) -> String = { name in self.byte(device, name).map(String.init) ?? "unavailable" }
            return "connected=\(device.isConnected()),multiBattery=\(value("isMultiBatteryDevice")),earDetection=\(value("inEarDetect")),primarySide=\(value("primaryBud")),primaryInEar=\(value("primaryInEar")),secondaryInEar=\(value("secondaryInEar"))"
        }.joined(separator: "; ")
        // Explicit diagnostic data only: no device names, addresses, tokens,
        // serial numbers or metadata history. This explains unsupported APIs
        // instead of silently treating a missing ear-state feed as evidence.
        diagnosticStatus = "Paired \(devices.count); connected \(connected.count); ear-capable \(supported.count). \(fields)"
        let eligible = devices.filter {
            $0.isConnected() && byte($0, "isAppleDevice") == 1 &&
            byte($0, "isMultiBatteryDevice") == 1 &&
            byte($0, "isInEarDetectionSupported") == 1 && byte($0, "inEarDetect") == 1
        }
        guard eligible.count == 1, let device = eligible.first,
              let primary = byte(device, "primaryBud"), primary <= 1,
              let first = byte(device, "primaryInEar"), first <= 1,
              let second = byte(device, "secondaryInEar"), second <= 1 else { return nil }
        if selected?.isEqual(device) != true { selected = device; token = UUID().uuidString }
        // The private fields use zero for in-ear; primaryBud == 1 is left.
        let left = primary == 1 ? first : second
        let right = primary == 1 ? second : first
        let mask: UInt8 = (left == 0 ? 1 : 0) | (right == 0 ? 2 : 0)
        return AirPodsWearReading(deviceToken: token, wornMask: mask,
            receipt: ProcessInfo.processInfo.systemUptime)
    }

    private func byte(_ object: NSObject, _ name: String) -> UInt8? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        // Do not call a selector with an ABI other than a boolean/byte getter.
        guard ["B", "c", "C"].contains(String(cString: returnType)) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(object, selector)
    }
}
