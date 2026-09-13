# Camera reference with AirPods motion: heading fusion design

Research date: 13 September 2026. Status: proposed architecture, not implemented or hardware validated. The existing wearer test failed to preserve the original screen-facing direction through rewear using the AirPods reference alone. This report designs an optional local camera aid; it does not authorize camera activation.

## Decision

Keep two different references. A **camera center** records the head direction when the user explicitly faces the chosen screen. An **AirPods alignment** maps the current sensor coordinate system to that saved camera center. Rewear may replace the AirPods alignment; it must never replace the camera center.

A short camera burst can observe that the returning wearer is looking 35° away. Combining that observation with simultaneous AirPods data restores a 35° output even if the AirPods now report zero. Stillness can make the observation easier to match; it cannot establish screen-facing zero.

The first implementation should be a seated, predominantly horizontal head-turn estimator. Apple Vision exposes face yaw, pitch, and roll; this is camera-relative face pose, not a surveyed screen direction, eye gaze, or compass measurement.[^vision-pose] The proposed method depends on a fixed camera/display arrangement and a validated operating range. It cannot promise recovery when the face is invisible or the camera has moved.

## What the sources establish

| Question | Evidence and consequence |
| --- | --- |
| Can built-in Vision provide changing face angles? | Apple introduced continuous yaw, pitch, and roll with face detector revision 3. Run a face detector for each accepted pose frame; pin a supported request revision. These are estimates, with no numerical accuracy guarantee in the cited material.[^vision-pose] |
| Is yaw always present? | `VNFaceObservation.yaw` is optional, in radians about the face y-axis. A missing value is unusable, not zero.[^yaw] |
| Does a tracking rectangle supply a fresh face angle? | Apple describes object tracking results as position and extent observations. Use tracking only to associate regions; obtain fresh pose from a face detection request.[^tracking] |
| Is confidence a yaw error bound? | No such bound is documented. An observation confidence of 1 can also mean confidence is unsupported or has no assigned meaning.[^confidence] Face capture quality is a comparative quality measure for the same subject, not a substitute for pose uncertainty.[^vision-pose] |
| How are camera times represented? | Capture output timestamps use the session synchronization clock. Core Media can convert times between clocks, including the host clock.[^capture-clock][^clock-conversion] |
| Are AirPods timestamps proven to use the Mac's clock? | `CMLogItem.timestamp` is documented as seconds since the device booted. That wording alone does not identify the Mac versus the accessory clock for headphones. This report found no primary-source guarantee resolving that ambiguity.[^motion-time] |
| Can the headphone manager select a north frame? | The documented headphone start API takes a queue and handler. Do not transfer the general `CMMotionManager` reference-frame selection API to headphones.[^headphone-start] |
| What saves camera power? | Stop the capture session when its data is no longer needed and use the lowest suitable capture quality. Dropping analysis frames while leaving the camera running is not the same as stopping capture.[^camera-energy] |

## The measurement model

All engine angles are radians. Positive means a physical left head turn as verified during setup. Define `W(x) = atan2(sin(x), cos(x))`, with a consistent chosen representation at the ±π endpoint.

For the selected camera and screen, let `c0` be the explicit screen-facing camera yaw after applying a verified camera sign. A fresh camera observation is:

```text
cameraRelative(t) = W(signCamera × visionYaw(t) − c0)
```

Let `s_e(t)` be the AirPods yaw in sensor epoch `e`, with its own verified physical sign. This scalar must be available independently of whether the old manual center is usable. It must not be the current `yawDegrees` property if that property freezes when manual calibration becomes invalid.

During an accepted camera burst, estimate an offset from matched measurements:

```text
b_j = W(cameraRelative(t_j) − s_e(t_j))
b_e = atan2(Σ w_j sin(b_j), Σ w_j cos(b_j))
heading(t) = W(s_e(t) + b_e)
```

Before the circular mean, reject outliers around a circular median or a robust initial consensus. Require a tight residual cluster; reject an ambiguous circular mean with a near-zero resultant. Confidence may contribute a weight after admission, but cannot make a geometrically or temporally invalid observation admissible.

Example: the stored camera center is 4°. After rewear at physical +35°, the signed camera yaw is 39° and the new sensor yaw is −8°. `cameraRelative = 35°`, `b = 43°`, and the fused heading is 35°. Later the sensor moves to −43° while the wearer returns to the original direction; the output becomes 0°. The stored 4° center and its revision remain unchanged.

Within an uninterrupted epoch, keep `b_e` fixed between camera checks. Do not continuously shrink `s_e`, `b_e`, or the final heading toward zero when the wearer holds a turn. The existing blur response can smooth effect strength without changing the measured zero.

### Three-dimensional boundary

Scalar offset fusion assumes the two yaw signals represent the same horizontal rotation over the operating range. It is not a general identity for subtracting arbitrary Euler rotations. A tilted camera, large head roll/pitch, a changed earbud-to-head fit, or a changed sensor axis convention can violate it.

For the first version, gate excessive camera pitch/roll and validate sign, scale, and residual error on modest left/right sweeps. Use the existing normalized quaternion adapter to derive sensor yaw, but validate its relationship to Vision on the actual device and source location. A future full 3D version would require an explicitly defined camera/head/sensor rotation convention and a calibrated rigid transform. Do not synthesize that transform by assuming Vision Euler rotation order or treating its angles as the Core Motion axes.

## Timing: measure the frame time, not the callback time

On the camera acquisition queue, capture the frame's presentation timestamp and current session clock. Convert the timestamp to the host clock with `CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())`. Reject invalid, indefinite, nonfinite, implausibly future, or old converted times. Record callback receipt separately. Capture-session restart, clock changes, and camera input changes create a new camera generation. Never combine a frame's timestamp with a clock from a later generation.[^capture-clock][^clock-conversion]

On the headphone acquisition queue, retain the source timestamp, a host-clock receipt timestamp, sensor epoch, yaw, and angular speed. Use the same chosen host clock for new camera/fusion data. Existing `ProcessInfo.systemUptime` watchdog behavior can remain, but do not mix its numeric values with Core Media host seconds without checking the conversion convention and sleep behavior.

The fusion engine should represent mapped motion time as a host-time **interval**, not an implicitly exact receipt timestamp. If the source clock is verified against host time, interpolate the sensor yaw at camera capture time between adjacent samples of the same epoch. Unwrap locally or interpolate on the unit circle; never average +179° and −179° as zero. Do not interpolate across a source change, timestamp reset, continuity event, or a large sample gap. Do not extrapolate to cover an old frame.

A useful bound for matching error is:

```text
angularTimingError ≤ maximumAngularSpeed × timeUncertainty
```

For example, 100 ms uncertainty during a 90°/s turn can produce 9° of error, enough to cross the current blur onset. A frame that arrived now may describe an earlier head direction.

### Conservative first implementation

Do not ship moving-head reanchoring before the headphone clock relationship and end-to-end latency are measured. A practical first prototype can require both a nearly stationary face-pose burst and an extended low-motion AirPods interval that covers the camera capture times **plus a latency guard before and after**. Accept the measured off-axis angle; never substitute zero.

This fallback still depends on a bound for motion transport delay. The existing minimum receipt/source offset detects added delay; it does not prove absolute delay. An affine source-to-host estimate from receipt samples is a candidate clock model, not a synchronization guarantee. Unknown timing uncertainty must remain unknown. If no defensible bound is available, refuse automatic alignment and show that matching is still in progress; use an explicitly labeled experimental policy only for a controlled, consented hardware test.

As provisional test parameters, evaluate 0.8 seconds of low motion, at least three admitted camera observations spanning at least 0.5 seconds (compatible with a 3 fps analysis cadence), sensor speed below 5°/s, and camera pose spread below 2°. These are proposed engineering gates, not Apple accuracy specifications. Their adequacy depends on measured timing and pose errors. Hold the pose long enough to cover the measured worst-case delay; a single stable sample or matching callback receipts is insufficient.

## Camera geometry and setup

Setup must explicitly ask the user to face the chosen reference screen and save `c0` from an admitted burst. Then ask for a modest physical left/right turn to verify the camera sign and sensor sign independently. Camera sign must not be silently inferred from a preview's appearance. AVFoundation can mirror the actual video data, and automatic mirroring may change with session configuration.[^mirroring] Process a deliberately configured, known orientation using `VNImageRequestHandler`'s orientation parameter; keep preview-only mirroring separate.[^orientation]

Persist only a small calibration record: selected camera identity, reference display identity, configuration/geometry signature, signed neutral yaw, verified sign conventions, Vision request revision, schema version, and calibration revision. A scalar neutral may be persisted across app restarts; the sensor offset may not. The calibration belongs to that physical setup, not universally to the person.

For multiple displays, either use one named reference screen for all effects or explicitly calibrate each screen's direction. Do not infer physical screen angles from desktop pixel coordinates. A moving laptop lid, an external camera adjustment, a different seat position, or turning an external display can change the relationship. Detect known device/configuration changes and ask for setup again. Ordinary device IDs cannot detect every physical camera move; explain this limit and provide a visible “Update screen center” action.

Prefer an explicitly selected fixed camera. Apple's Continuity Camera sample supports automatic camera switching and observes externally changed video effects; those conveniences require different treatment here because a different camera invalidates geometry.[^camera-selection] Do not silently use a phone camera or the newly preferred system camera. For the initial tested configuration, avoid Center Stage/automatic reframing, digital zoom, and stabilization changes; observe effects and invalidate or suspend when the geometry signature changes. Do not claim every crop change alters true pose, but do not assume the estimator is invariant without testing.

Camera yaw is an estimate from an image. Moving sideways can change perspective and the apparent face angle even when the head's world orientation stays constant. Reject large departures from the calibrated face position/scale for the first version, then measure how restrictive this is in normal seated use. Do not call this a complete geometric screen model: that would require camera intrinsics, camera/display extrinsics, and head position as well as orientation.

## Admission and ambiguity

Admit a camera sample only when all numeric fields are finite, required pose values exist, camera/generation/configuration match, frame age and timing are acceptable, and the pose lies in the validated range. Initial engineering limits worth testing are absolute yaw up to 45°, pitch up to 20°, and roll up to 15°, with a sufficiently large, unclipped face. These limits should be tightened or expanded from measurements; they are not documented Vision limits.

For the first version, require exactly one eligible face. Several faces, no face, occlusion, poor lighting, or a profile beyond the tested range yield no anchor. Do not substitute the largest face, a cached face angle, or zero. A tracking identifier associates observations within a burst; it does not authenticate the AirPods wearer or establish persistent identity. Even a single visible face may be someone else. Local motion agreement during setup/checks helps detect some mismatches, but this feature is not security-grade wearer recognition.

A confidence threshold alone is insufficient. Evaluate pose dispersion, face size/position, clipping, frame age, sensor speed, timing uncertainty, and sensor/camera angular-change agreement. Where camera angle changes but sensor angle does not—or vice versa—refuse the proposed offset and collect another burst. Strongly correlated systematic Vision bias can survive averaging, so hardware error measurements remain necessary.

Missing camera observations do not automatically invalidate a fresh, already aligned inertial epoch. They do prevent a new epoch from being aligned. After rewear at a large angle where no usable face is visible, the app may have to wait until the wearer turns enough to become visible. It can then recover the original zero without asking that visible pose to be zero; it cannot promise immediate recovery at every angle.

## Epochs, corrections, and lifecycle

Use typed events and monotonically increasing generations, not status-string parsing. Camera mode creates a new, unaligned sensor epoch on disconnect/rewear, source-location handoff, manager/stream restart, clock reset, or detected attitude discontinuity. This is stricter than the prior retained-reference experiment because the physical rewear test disproved relying on that continuity.

Keep the camera center through these sensor events. Clear the ephemeral offset and queued pairings immediately. A fresh scalar sensor pose may become available while the fused heading remains unusable. Once a valid burst supplies a new offset, align the current epoch without invoking `MotionService.calibrate()` and without incrementing the user's center revision.

For occasional same-epoch drift checks, compare a candidate offset to the existing one. Only apply a small, well-supported correction when motion and timing are admissible. A large discrepancy should pause the effect and request a new anchor burst. Never gradually blend across a suspected reset while continuing to report valid privacy tracking. A false jump detector can also trigger this path; a valid camera measurement can recover it without asserting that the jump was definitely an Apple reset.

Commit an alignment atomically only if camera generation, sensor epoch, center revision, selected display, permission/opt-in state, and active-session generation still match the request. Recheck those values after every asynchronous wait. Old callbacks cannot realign after pause, camera disable, removal, sleep, display change, or another reset.

Retain prior effect intent separately from alignment. A successful automatic reanchor may resume an effect interrupted by removal or tracking loss only if the user had enabled it and the Mac session is active. Explicit Pause cancels automatic effect resumption. Camera recovery must not cause display sleep, fake an ear-removal event, or override the existing removal debounce.

If tracking becomes unusable, preserve the app's existing safe pause-and-clear behavior rather than trapping the desktop behind an uncertain overlay. Do not advertise guaranteed visual privacy during a camera/motion outage. Any separate deliberate display-off policy remains an explicit user setting.

## Proposed implementation boundaries

`HeadingFusionEngine.swift` should import Foundation only and have no devices, timers, UI, storage, or permission calls. Its inputs and outputs should be immutable value types with radians and an explicit host-time convention:

```text
CameraCenter:
  cameraID, displayKey, geometrySignature, revision,
  neutralYawRadians, cameraSign, sensorSign, poseRevision

InertialHeadingSample:
  epoch, sourceTime, receiptHostTime,
  measurementHostInterval?, yawRadians, angularSpeed, fresh

CameraHeadingSample:
  generation, cameraID, geometrySignature,
  captureHostTime, receiptHostTime,
  yawRadians?, pitchRadians?, rollRadians?, confidence,
  eligibleFaceCount, faceBounds

FusionOutput:
  state, headingRadians?, sensorEpoch, centerRevision,
  alignmentRevision, lastAnchorHostTime?, rejectionReason?
```

The engine accepts motion samples, camera samples, explicit invalidation events, and a supplied `now`; it exposes a current output whose freshness is checked at consumption. Keep only a bounded approximately two-second numeric motion ring and the current burst's pose summaries in memory. Clearing a generation clears those buffers. Do not retain camera frames after analysis, write pose histories, or persist an epoch alignment.

`MotionService` should expose an independent fusion sample stream: normalized sample quaternion-derived yaw, angular speed, source timestamp, acquisition receipt time, source key, and epoch. Its camera-mode epoch can advance without destroying the separate manual calibration path. Give the engine real acquisition samples or a bounded snapshot; main-thread published-property timing must not masquerade as acquisition timing. Explicit duplicate connect callbacks alone must not repeatedly create epochs.

`CameraAnchorService` owns permission-gated AVFoundation/Vision work, converted frame times, immutable results, and explicit burst start/stop. It should use a serial queue, late-frame discard, and a bounded analysis queue; Apple describes the one-frame late-drop policy and the need to keep callbacks efficient.[^frame-drops] Returning a pose after a burst timeout must not revive a canceled request.

`AppModel` owns persistence, settings, burst scheduling, session gates, and choosing manual versus fused output. The renderer consumes one final heading and validity value. It should have no camera assumptions. The visible Set center action is the only action that changes `CameraCenter.revision`; successful reanchors increment a separate alignment counter.

## Privacy, user interface, and power

Default camera assistance to off. Only the user's explicit enable/setup action may request video authorization. Recheck authorization before configuring capture; do not construct a camera input first and unintentionally trigger the system prompt. Include the appropriate camera purpose string and signing configuration. No microphone input or audio permission is needed for this design.[^camera-permission]

All analysis stays on the Mac. Persist calibration numbers, not images or face templates. Explain that a camera session is actually used briefly and that its system indicator may appear; never present “camera off” while a session still captures. Camera denial, revocation, occupancy by another app, or disappearance is an ordinary unavailable state. Do not loop permission prompts or silently switch hardware.

Suggested visible states are “Camera assistance is off,” “Set your screen center,” “Checking your head direction,” “Ready,” “Keep your face visible briefly,” and “More than one face is visible.” The helper should explain that the center stays saved and the camera measures the returning angle. Never say “Face the screen to restore” after rewear unless the camera setup itself has become invalid.

Start with event-triggered bursts after rewear, sensor reset, wake if alignment is untrusted, or explicit setup. Stop capture as soon as an anchor succeeds or a short deadline expires. A prototype can test a two-second burst deadline, at most one queued burst, and retries with 2/5/15-second backoff followed by a user-visible waiting state. Suspend retries while absent, locked, sleeping, manually disabled, or no effect/setup needs them. These are proposed budgets, not power measurements.

Choose the lowest resolution and frame rate that meet measured pose accuracy; a 640×480-class input at a supported modest rate is a starting experiment, not a promise of adequacy. Measure start-up latency and energy because repeated camera warm-up may cost more than expected. Optional infrequent drift checks should be added only after measuring whether they improve error enough to justify camera activation. Stopping the camera between bursts follows Apple's energy guidance.[^camera-energy]

## Tests and release gates

The pure engine and real coordinator boundaries need tests that verify these outcomes:

1. Establish original zero, reset sensor at +35°, observe +35° by camera, and return physically to zero. Output follows 35°→0°; camera center and revision never change.
2. Hold +35° for ten seconds through several camera checks. Heading never decays toward zero. A compatible small drift correction changes the offset rather than the zero record.
3. Sensor and camera signs are independently reversed; verified sign adapters restore physical left/right. Mirroring/configuration changes reject an old calibration.
4. Angles cross +179°/−179°; interpolation, residuals, outlier rejection, and circular mean follow the short arc. Antipodal ambiguous observations are rejected.
5. Delayed camera frames during a turn fail timing admission. Unknown clock mapping never becomes zero uncertainty. Added transport delay, clock drift, clock reset, and sleep break old pairing windows.
6. A source handoff or reset during a burst prevents commit. Duplicate connect callbacks do not repeatedly invalidate a good epoch. No samples are interpolated across epoch boundaries.
7. Missing angles, NaN, infinity, stale/future times, no face, multiple faces, outliers, clipped faces, and unsupported pitch/roll all fail without substituting zero.
8. Camera disable, permission denial, manual pause, sleep, display selection, and center updates cancel queued work before and after asynchronous completion. No test activates hardware or invokes display sleep.
9. A reset while the wearer is looking away can recover at that same visible off-axis pose; if the face is invisible, output stays paused until a valid observation arrives.
10. Cold launch with a stored camera center starts unaligned. Only a new valid burst can supply the new session's sensor offset. Resetting preferences discards the geometric center explicitly.

Before automatic restoration is presented as dependable, run an opted-in physical test with known screen-facing zero and measured left/right directions. Repeat removal and source handoff while looking away, returning to zero, held turns, fast turns, mixed pitch/roll, glasses, dim/backlighting, different seating positions, and camera configuration changes. Report median and worst observed heading error, zero-return error, rejected-anchor rate, recovery time, and energy/camera-active time. A provisional design target is a 95th-percentile error below 3° inside the admitted range, chosen to leave margin under the current 8° onset; this is an acceptance target, not an achieved result.

The first hardware gate is especially important: verify camera sign and headphone-to-camera clock behavior without enabling the desktop effect. Then check restoration at off-axis poses. Only after those pass should the existing effect consume fused headings. Sparse monocular estimates cannot guarantee continuous absolute heading, recognize the wearer securely, or detect every camera movement. The useful, testable promise is narrower: recover the saved screen-relative head direction when a trustworthy camera observation and matching fresh AirPods data are available.

## Sources

[^vision-pose]: Apple, [Detect people, faces, and poses using Vision, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10040/), face detector revision 3 and face capture quality discussion. Accessed 2026-09-13.
[^yaw]: Apple, [VNFaceObservation.yaw](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw), optional yaw semantics. Accessed 2026-09-13.
[^tracking]: Apple, [Tracking Multiple Objects or Rectangles in Video](https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video), object tracking result types and bounding boxes. Accessed 2026-09-13.
[^confidence]: Apple, [VNObservation.confidence](https://developer.apple.com/documentation/vision/vnobservation/confidence), including the meaning of confidence 1. Accessed 2026-09-13.
[^capture-clock]: Apple, [AVCaptureSession.synchronizationClock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock), capture timestamps and synchronization. Accessed 2026-09-13.
[^clock-conversion]: Apple, [CMSyncConvertTime](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:)), host clock conversion and drift. Accessed 2026-09-13.
[^motion-time]: Apple, [CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp), time since device boot. Accessed 2026-09-13.
[^headphone-start]: Apple, [CMHeadphoneMotionManager.startDeviceMotionUpdates(to:withHandler:)](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/startdevicemotionupdates(to:withhandler:)), headphone-specific start signature. Accessed 2026-09-13.
[^mirroring]: Apple, [AVCaptureConnection.isVideoMirrored](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/isvideomirrored) and [automaticallyAdjustsVideoMirroring](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/automaticallyadjustsvideomirroring), actual buffer mirroring and automatic changes. Accessed 2026-09-13.
[^orientation]: Apple, [VNImageRequestHandler init(cmSampleBuffer:orientation:options:)](https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(cmsamplebuffer:orientation:options:)-335k4), explicit input orientation and buffer metadata. Accessed 2026-09-13.
[^camera-selection]: Apple, [Supporting Continuity Camera in your macOS app](https://developer.apple.com/documentation/avfoundation/supporting-continuity-camera-in-your-macos-app), automatic camera changes and observable video effects. Accessed 2026-09-13.
[^frame-drops]: Apple, [TN2445: Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), bounded late-frame delivery and processing guidance. Accessed 2026-09-13.
[^camera-permission]: Apple, [Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media) and [requestAccess(for:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)), permission timing and input creation. Accessed 2026-09-13.
[^camera-energy]: Apple, [Reducing power usage when capturing media](https://developer.apple.com/documentation/xcode/reducing-power-usage-when-capturing-media), stop sessions and choose suitable formats. Accessed 2026-09-13.
