import AppKit
import AVFoundation
import CoreMotion
import ScreenCaptureKit

extension PermissionOnboarding {
    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, provider: SystemPermissionOnboardingProvider())
    }
}

/// Reads macOS permission state without starting any sensor or capture stream.
/// Request methods are reached only after the user reads and chooses Allow.
@MainActor final class SystemPermissionOnboardingProvider: PermissionOnboardingProviding {
    private var motionRequest: CMHeadphoneMotionManager?
    private var requestGeneration = 0

    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot {
        switch permission {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return PermissionAccessSnapshot(.authorized)
            case .notDetermined: return PermissionAccessSnapshot(.notDetermined)
            case .denied: return PermissionAccessSnapshot(.denied)
            case .restricted: return PermissionAccessSnapshot(.restricted)
            @unknown default: return PermissionAccessSnapshot(.restricted)
            }
        case .screenRecording:
            // A false preflight cannot distinguish an unrequested permission
            // from a denial or a change that requires an application restart.
            return PermissionAccessSnapshot(CGPreflightScreenCaptureAccess() ? .authorized : .notGranted)
        case .headTracking:
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .authorized: return PermissionAccessSnapshot(.authorized)
            case .notDetermined: return PermissionAccessSnapshot(.notDetermined)
            case .denied: return PermissionAccessSnapshot(.denied)
            case .restricted: return PermissionAccessSnapshot(.restricted)
            @unknown default: return PermissionAccessSnapshot(.restricted)
            }
        }
    }

    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot {
        let before = status(for: permission)
        if before.authorization == .authorized || before.authorization == .restricted { return before }
        switch permission {
        case .camera:
            guard before.authorization == .notDetermined else { return before }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            return status(for: permission)
        case .screenRecording:
            do {
                // Ask ScreenCaptureKit to verify access. No SCStream is created,
                // no screen pixels are captured, and window metadata is discarded.
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let after = status(for: permission)
                return after.authorization == .authorized ? after : PermissionAccessSnapshot(.notGranted,
                    message: "macOS has not confirmed access for this session. Reopen AirVeil if System Settings asks, then check again. Your setup progress is saved.")
            } catch {
                let error = error as NSError
                if error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue {
                    return PermissionAccessSnapshot(.denied,
                        message: "Screen Recording was not allowed. You can change it in System Settings or continue with the preview.")
                }
                return PermissionAccessSnapshot(.notGranted,
                    message: "macOS could not verify Screen Recording access. Check System Settings and try again. \(error.localizedDescription)")
            }
        case .headTracking:
            guard before.authorization == .notDetermined else { return before }
            return await requestHeadTracking()
        }
    }

    private func requestHeadTracking() async -> PermissionAccessSnapshot {
        cancelPendingRequest()
        requestGeneration += 1
        let generation = requestGeneration
        let manager = CMHeadphoneMotionManager()
        motionRequest = manager
        defer {
            manager.stopDeviceMotionUpdates()
            if generation == requestGeneration { motionRequest = nil }
        }
        guard manager.isDeviceMotionAvailable else {
            return PermissionAccessSnapshot(.unavailable,
                message: "Connect and wear compatible AirPods, then choose Try again. AirVeil has not received a permission decision yet.")
        }
        // Core Motion has no separate headphone-motion permission request API.
        // A short, explicit request session is stopped on every exit path.
        manager.startDeviceMotionUpdates(to: .main) { _, _ in }
        for _ in 0..<80 {
            let current = status(for: .headTracking)
            if current.authorization != .notDetermined { return current }
            guard generation == requestGeneration, !Task.isCancelled else { return current }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return status(for: .headTracking) }
        }
        return PermissionAccessSnapshot(.notDetermined,
            message: "No permission decision arrived. Make sure your AirPods are connected and worn, then try again.")
    }

    func openSettings(for permission: AirVeilPermission) {
        let anchor: String
        switch permission {
        case .camera: anchor = "Privacy_Camera"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .headTracking: anchor = "Privacy_Motion"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    func cancelPendingRequest() {
        requestGeneration += 1
        motionRequest?.stopDeviceMotionUpdates()
        motionRequest = nil
    }
}
