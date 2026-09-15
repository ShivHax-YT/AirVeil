import Foundation
import CoreGraphics

/// Anonymous geometry from the most recent successful center check. Never an
/// image, facial descriptor, or claim of identity. The caller owns layout and
/// wear-session validity; a stationary seat reference does not expire by age.
struct PresenceSeatReference: Equatable, Sendable {
    let cameraID: String
    let configurationID: String
    let faceBounds: CGRect
    let captureHostTime: Double
}

struct PresenceBody: Equatable, Sendable {
    let bounds: CGRect
    let confidence: Double
}

struct PresenceObservation: Equatable, Sendable {
    let cameraID: String
    let configurationID: String
    let captureHostTime: Double
    let receiptHostTime: Double
    let bodies: [PresenceBody]
    let faces: [CGRect]
    var analysisUsable = true
    var needsLightAssistance = false
}

enum PresenceState: String, Equatable, Sendable { case unknown, present, absent }

struct PresenceSnapshot: Equatable, Sendable {
    var state: PresenceState = .unknown
    var status = "Checking the foreground seat."
    var bodyBounds: CGRect?
}

/// Spatial continuity, not person recognition. A background/side person must
/// not keep the display awake after the foreground track leaves. Somebody
/// replacing the occupant in the same seat without a visible gap cannot be
/// distinguished by geometry alone; this is not an authentication mechanism.
struct PresenceTracker {
    static let frameFreshness = 1.2
    static let absentHold = 1.5
    private let reference: PresenceSeatReference
    private var tracked: CGRect?
    // Face-only confirmation has no torso rectangle, but has the same
    // continuity requirement as a confirmed upper-body track.
    private var foregroundConfirmed = false
    private var candidate: CGRect?
    private var candidateStarted: Double?
    private var candidateCount = 0
    private var lastCapture: Double?
    private var lastReceipt: Double?
    private var missingSince: Double?
    private var missingFrames = 0
    private var absenceLatched = false
    private var continuityLost = false
    private(set) var snapshot = PresenceSnapshot()

    init(reference: PresenceSeatReference) { self.reference = reference }

    static func isReferenceUsable(_ reference: PresenceSeatReference, now: Double) -> Bool {
        !reference.cameraID.isEmpty && !reference.configurationID.isEmpty &&
        reference.captureHostTime.isFinite && reference.captureHostTime >= 0 &&
        now.isFinite && now >= reference.captureHostTime &&
        usableRect(reference.faceBounds) && reference.faceBounds.width >= 0.08 && reference.faceBounds.height >= 0.08
    }

    mutating func observe(_ observation: PresenceObservation, now: Double) -> PresenceSnapshot {
        guard !absenceLatched else { return snapshot }
        guard !continuityLost else {
            snapshot = PresenceSnapshot(status: "Foreground continuity was interrupted. Wear your AirPods to start a new check.")
            return snapshot
        }
        guard Self.isReferenceUsable(reference, now: now),
              observation.cameraID == reference.cameraID,
              observation.configurationID == reference.configurationID else {
            continuityLost = true
            snapshot = PresenceSnapshot(status: "Camera framing changed. Set center again before checking presence.")
            return snapshot
        }
        guard observation.captureHostTime.isFinite, observation.receiptHostTime.isFinite,
              observation.captureHostTime >= 0,
              observation.receiptHostTime >= observation.captureHostTime,
              now >= observation.receiptHostTime,
              now - observation.captureHostTime <= Self.frameFreshness,
              observation.receiptHostTime - observation.captureHostTime <= 0.8 else {
            snapshot = PresenceSnapshot(status: "Waiting for a fresh presence frame.")
            return snapshot
        }
        if let lastCapture, observation.captureHostTime <= lastCapture { return snapshot }
        if let lastReceipt, observation.receiptHostTime - lastReceipt > Self.frameFreshness, foregroundConfirmed {
            continuityLost = true
            snapshot = PresenceSnapshot(status: "The camera frame gap interrupted foreground continuity.")
            return snapshot
        }
        lastCapture = observation.captureHostTime; lastReceipt = observation.receiptHostTime
        let plausible = observation.bodies.filter { body in
            guard body.confidence.isFinite, body.confidence >= 0.6, body.confidence <= 1,
                  Self.usableRect(body.bounds), isForegroundSize(body.bounds) else { return false }
            if let tracked { return Self.follows(body.bounds, tracked) }
            return matchesSeat(body.bounds)
        }
        let foregroundFaces = observation.faces.filter { face in
            guard Self.usableRect(face) else { return false }
            let saved = reference.faceBounds
            return face.width >= saved.width * 0.8 && face.height >= saved.height * 0.8 &&
                abs(face.midX - saved.midX) <= max(0.1, saved.width * 0.7) &&
                abs(face.midY - saved.midY) <= max(0.1, saved.height * 0.7)
        }
        if !observation.analysisUsable, plausible.isEmpty, foregroundFaces.isEmpty {
            candidate = nil; candidateCount = 0; candidateStarted = nil
            missingSince = nil; missingFrames = 0
            snapshot = PresenceSnapshot(status: "The camera cannot reliably check the foreground seat in this view.")
            return snapshot
        }
        // Never silently select a different member of an overlapping crowd.
        guard plausible.count <= 1, foregroundFaces.count <= 1 else {
            candidate = nil; candidateCount = 0; candidateStarted = nil
            missingSince = nil; missingFrames = 0
            snapshot = PresenceSnapshot(status: "More than one person overlaps the foreground seat.")
            return snapshot
        }
        if plausible.isEmpty, foregroundFaces.count == 1 {
            // A clear foreground face is useful when the torso is cropped or
            // the body detector misses a frame. It is optional: a profile or
            // back view remains present from body evidence alone.
            missingSince = nil; missingFrames = 0
            if candidateStarted == nil { candidateStarted = observation.captureHostTime }
            candidateCount += 1
            if tracked != nil || (candidateCount >= 3 && observation.captureHostTime - candidateStarted! >= 0.5) {
                foregroundConfirmed = true
                snapshot = PresenceSnapshot(state: .present,
                    status: "The foreground seat is occupied.", bodyBounds: tracked)
            } else {
                snapshot = PresenceSnapshot(status: "Confirming the foreground seat occupant.")
            }
            return snapshot
        }
        guard let body = plausible.first?.bounds else {
            candidate = nil; candidateCount = 0; candidateStarted = nil
            if missingSince == nil { missingSince = observation.captureHostTime }
            missingFrames += 1
            if missingFrames >= 3, observation.captureHostTime - missingSince! >= Self.absentHold {
                absenceLatched = true
                snapshot = PresenceSnapshot(state: .absent, status: "The foreground occupant has left the camera view.")
            } else {
                snapshot = PresenceSnapshot(status: "Checking whether the foreground occupant has left.")
            }
            return snapshot
        }
        missingSince = nil; missingFrames = 0
        if tracked == nil {
            if let candidate, !Self.follows(body, candidate) {
                candidateStarted = nil; candidateCount = 0
            }
            candidate = body
            if candidateStarted == nil { candidateStarted = observation.captureHostTime }
            candidateCount += 1
            guard candidateCount >= 3, observation.captureHostTime - candidateStarted! >= 0.5 else {
                snapshot = PresenceSnapshot(status: "Confirming the foreground seat occupant.", bodyBounds: body)
                return snapshot
            }
        }
        tracked = body
        foregroundConfirmed = true
        snapshot = PresenceSnapshot(state: .present,
            status: "The foreground seat is occupied. Head direction is not required.", bodyBounds: body)
        return snapshot
    }

    mutating func tick(now: Double) -> PresenceSnapshot {
        guard !absenceLatched, now.isFinite else { return snapshot }
        if let lastReceipt, now - lastReceipt > Self.frameFreshness {
            if foregroundConfirmed { continuityLost = true }
            snapshot = PresenceSnapshot(status: "Presence frames stopped arriving. The occupant cannot be confirmed.")
        }
        return snapshot
    }

    private func isForegroundSize(_ bounds: CGRect) -> Bool {
        let face = reference.faceBounds
        return bounds.width >= face.width * 1.15 && bounds.height >= face.height * 1.25 &&
            bounds.width * bounds.height >= max(0.08, face.width * face.height * 3)
    }

    private func matchesSeat(_ bounds: CGRect) -> Bool {
        let face = reference.faceBounds
        // A foreground torso must include the calibrated head region and have
        // the corresponding scale. Merely detecting any face/person is not enough.
        return abs(bounds.midX - face.midX) <= max(0.12, face.width * 0.9) &&
            bounds.minY < face.midY && bounds.maxY >= face.maxY - face.height * 0.3 &&
            bounds.intersection(face).width >= face.width * 0.55
    }

    private static func follows(_ next: CGRect, _ previous: CGRect) -> Bool {
        let intersection = next.intersection(previous)
        let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
        let oldArea = previous.width * previous.height, newArea = next.width * next.height
        let union = oldArea + newArea - overlap
        return union > 0 && overlap / union >= 0.30 &&
            abs(next.midX - previous.midX) <= 0.18 && abs(next.midY - previous.midY) <= 0.22 &&
            newArea / oldArea >= 0.5 && newArea / oldArea <= 2
    }

    private static func usableRect(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
        rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0 &&
        rect.maxX <= 1.001 && rect.maxY <= 1.001
    }
}
