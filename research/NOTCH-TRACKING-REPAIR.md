# AirVeil notch tracking repair

The notch regression has two concrete causes in the application source: the rail represents face position instead of head rotation, and the new coaching presentation rejects evidence that the previous calibration path could accept. A timing race can now repeatedly clear an otherwise valid hold. Repairing those contracts should precede changes to visual fluidity or density.

This analysis concerns the source at `48aa3cbb5bfd2f22e901c6079c5b5578327ab894`, compared with the earlier camera implementation at `8e2e5c3`. It establishes source-level behavior and implementation recommendations; it does not establish measured AirPods latency or the success of a later repaired build. The screen-recording review is separate from this source and API analysis.

## Findings and confidence

| Finding | Evidence in inspected source | Assessment |
|---|---|---|
| Turning in place can leave the rail stationary. | `NotchCoachGuidance.observation` derives both errors exclusively from `faceBounds.midX/midY`; `AlignmentRail` consumes the horizontal error. Headphone yaw is absent from this path. | Confirmed defect relative to a head-turn indicator. |
| Coaching now changes calibration acceptance. | `CameraHeadingCoordinator.receive` returns and calls `clearEvidence()` unless the presentation phase is `.holding`. The earlier implementation proceeded directly to geometric/temporal fusion checks. | Confirmed regression. |
| Natural framing can unnecessarily block restoration. | The new presentation requires the face to lie near the middle of the square preview, including during recovery. Initial center setup also adds yaw/pitch limits of 12° and roll of 10°, tighter than the existing fusion envelope. | Confirmed extra restriction; the amount of delay it caused in the recording is not measured here. |
| A render tick can consume a camera sample before its matching future motion sample arrives. | Pending processing starts at `capture + 0.2 s`; `stableMotionYaw` separately requires an actual motion receipt at or beyond `capture + 0.2 s`. A nil result now wipes accumulated pairs and camera evidence. | Deterministic scheduling hazard. Its frequency depends on the independent callback cadences. |
| Preview adds work ahead of analysis and an unbounded UI handoff. | The capture callback now creates 320-pixel `CGImage` previews at up to 15 Hz before the 3 Hz Vision work. Each preview/frame schedules a separate main-actor task. | Confirmed added work and queue shape; a performance bottleneck remains an inference until measured. |
| Multiple holds and a second camera start already existed. | `finishCenter` clears the fusion history, stops the camera, and lets a later update start recovery in both revisions. | Existing overhead, not evidence of a newly introduced regression. |

The underlying `MotionService` and `HeadingFusionEngine` were unchanged between the two inspected commits. A wholesale rollback of those components is therefore poorly targeted. The principal regression boundary is the connection between coaching, evidence collection, and rendering.[^1]

## Head position and head rotation

Vision's face bounding box describes image location: coordinates are normalized against the processed image and start at its lower-left corner. This is suitable for a face-framing guide.[^2] Vision separately reports yaw around its y-axis, pitch around its x-axis, and roll around its z-axis, in radians; an unavailable angle is nil.[^3][^4][^5] Moving a face toward the left side of an image and rotating a head left are different observations.

Keep separate presentation values for **framing error** and **head angle**. The preview can continue using its existing mirrored crop coordinates. The rail should consume a fresh angular value, with a documented range and sign. Pitch or vertical framing must not be advertised as reactive when `AlignmentRail` accepts a vertical value but never renders it.

Core Motion supplies attitude relative to a reference frame, with quaternion, matrix, and Euler representations.[^6] Apple's relative-attitude operation mutates its receiver, so the existing adapter's copy-before-`multiply(byInverseOf:)` pattern should remain.[^7] Camera orientation, preview mirroring, and headphone axes need explicit adapters; merely calling both quantities “yaw” does not establish identical screen direction. The headphone manager documentation supplies a headphone-specific axes diagram.[^8]

During an established alignment, drive the rail from the newest valid fused headphone heading. During setup, camera yaw can supply direct pose feedback; observed camera-to-headphone sign correspondence can then allow headphone deltas to update that feedback between camera observations. A new sensor epoch invalidates that correspondence. Missing angles and stale samples should yield an unavailable indicator, rather than a fabricated zero that looks centered.

This is a presentation recommendation, not permission for a provisional visual angle to establish calibration. The existing learned sign establishes camera/sensor agreement; a physically labeled left/right convention still needs the application's existing axis convention or wearer verification.

## Calibration evidence and asynchronous timing

Calibration must depend on the captured evidence, not the wording or color selected for a coaching snapshot. Keep one valid face, valid pose values, confidence, known camera configuration, freshness, stationary overlap, and sensor-epoch continuity as explicit acceptance conditions. Use framing guidance to help the wearer, but do not let a thumbnail crop become a new geometric definition of the saved display direction.

The current timing hazard is small but consequential. Suppose capture occurs at host time `10.000`, the next eligible render update is `10.201`, and the motion receipts surrounding the future guard arrive at `10.195` and `10.215`. At `10.201`, the camera sample is removed from pending. It cannot yet pass the requirement for a motion receipt at or after `10.200`; the new path then discards all earlier hold evidence. A later receipt cannot repair that discarded sample.

Represent three outcomes explicitly: **waiting for paired motion**, **rejected evidence**, and **accepted pair**. Keep the waiting sample pending until its required motion interval exists or its original freshness deadline expires. A scheduling gap does not demonstrate head movement. Conversely, a real unstable interval, wrong epoch, invalid clock, or changed camera configuration should invalidate the relevant hold.

Apple documents `CMLogItem.timestamp` as the measurement's valid time, expressed as seconds since device boot.[^9] It does not, in the consulted headphone API pages, guarantee the identity of the remote headphone timestamp epoch with the Mac's Core Media clock or bound delivery delay. Retain acquisition host receipts, original timestamps, and epoch checks; do not replace a capture timestamp with processing or UI delivery time.

AVCapture output sample timestamps use the session synchronization clock. Apple explicitly discusses synchronization with external sources such as Core Motion through capture clocks.[^10] `CMSyncConvertTime` converts between clocks and permits the Core Media host clock as a destination.[^11] AirVeil already converts camera PTS to that host clock. Its stationary overlap is an explicit approximation for unknown headphone delivery latency, rather than proof of cross-device clock synchronization. Fix the pending race without silently shrinking that guard.

## Responsive data flow

Keep motion acquisition independent of camera preview and SwiftUI work. `CMHeadphoneMotionManager.startDeviceMotionUpdates(to:withHandler:)` accepts a caller-selected operation queue.[^12] AirVeil already uses a serial acquisition queue and a one-slot delivery buffer that retains continuity failures; preserve that behavior. Render from the latest fresh pose instead of waiting for an additional Vision result or a completed hold.

Apply the same bounded handoff principle to preview publication. At most one pending UI notification should own the newest preview. Replacing a superseded image is preferable to draining a backlog of obsolete thumbnails. Camera generations and cancellation checks must continue preventing old images from reappearing after a burst ends.

Apple recommends efficient sample-buffer delegates and `alwaysDiscardsLateVideoFrames` for interactive capture. That setting bounds the capture pipeline's final buffer to its newest frame, but does not fix chronically expensive processing.[^13] It also cannot, by itself, bound a separate queue of main-actor tasks created by the application. Perform heading analysis before optional preview conversion when both are due, and avoid multiplying evidence when publishing extra preview images.

Increasing Vision frequency alone is insufficient. The current three-sample setup window assumes at least 0.5 seconds between its first and last samples. Raising the analysis rate without changing time-based evidence collection could make the most recent three samples permanently fail that span requirement. Any rate adjustment must preserve a temporal window with enough distinct captures, not an accidental relationship between fixed count and nominal frame rate.

## Repair order and verification boundaries

1. Separate camera framing from angular rail input and publish fresh head motion independently of hold progress.
2. Remove presentation-dependent acceptance and fix the pending-frame readiness race while retaining actual safety and confidence checks.
3. Bound preview publication; prioritize acquisition/analysis over optional preview conversion.
4. Consider reusing the already validated ending setup evidence for alignment, or continuing recovery in the same capture session. Preserve its measured turned angle and saved center; never treat the last turn as zero.
5. Verify the timing race with deterministic source-level fixtures, plus fixed face bounds with changing yaw, stale motion, sensor resets, and rapid cancel/restart. A real wearer run remains necessary to assess physical direction, camera-angle bias, latency, and perceived response.

The completion criterion is responsive angular feedback while the check is still collecting valid evidence, followed by a reliable alignment without unnecessary retries. Neither a moving rail nor a success animation is evidence that sensor fusion succeeded.

## Sources

[^1]: AirVeil local source at commits `48aa3cbb5bfd2f22e901c6079c5b5578327ab894` and `8e2e5c3`: `Sources/NotchCoachState.swift`, `NotchCoachView.swift`, `CameraHeadingCoordinator.swift`, `CameraAnchorService.swift`, `MotionService.swift`, `HeadingFusionEngine.swift`, and `AppModel.swift`. Read-only source comparison; observations describe those revisions, not subsequent edits.
[^2]: Apple, [VNDetectedObjectObservation.boundingBox](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox), current API documentation, accessed September 13, 2026.
[^3]: Apple, [VNFaceObservation.yaw](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw), current API documentation, accessed September 13, 2026.
[^4]: Apple, [VNFaceObservation.pitch](https://developer.apple.com/documentation/vision/vnfaceobservation/pitch), current API documentation, accessed September 13, 2026.
[^5]: Apple, [VNFaceObservation.roll](https://developer.apple.com/documentation/vision/vnfaceobservation/roll), current API documentation, accessed September 13, 2026.
[^6]: Apple, [CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude), current API documentation, accessed September 13, 2026.
[^7]: Apple, [CMAttitude.multiply(byInverseOf:)](https://developer.apple.com/documentation/coremotion/cmattitude/multiply(byinverseof:)), current API documentation, accessed September 13, 2026.
[^8]: Apple, [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager), current API documentation, accessed September 13, 2026.
[^9]: Apple, [CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp), current API documentation, accessed September 13, 2026.
[^10]: Apple, [AVCaptureSession.synchronizationClock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock), current API documentation, accessed September 13, 2026.
[^11]: Apple, [CMSyncConvertTime](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:)), current API documentation, accessed September 13, 2026.
[^12]: Apple, [CMHeadphoneMotionManager.startDeviceMotionUpdates(to:withHandler:)](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/startdevicemotionupdates(to:withhandler:)), current API documentation, accessed September 13, 2026.
[^13]: Apple, [Technical Note TN2445: Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), July 12, 2017; accessed September 13, 2026. This archived note is used for queue/processing behavior, not current device performance claims.
