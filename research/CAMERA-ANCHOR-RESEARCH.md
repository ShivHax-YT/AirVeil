# A camera reference for recovering AirPods head direction

## Recommendation

Use the Mac camera as an occasional independent reference and AirPods as the normal, responsive motion source. Establish the original screen-facing direction once in camera coordinates. After an AirPods reconnection, source transition, or detected orientation discontinuity, briefly observe the current face direction and align the new headphone coordinate frame to that stored camera reference. A successful recovery must preserve a real left or right turn; it must never declare the returning pose to be zero merely because the head is still.

This is feasible with public APIs on macOS 14: `AVCaptureVideoDataOutput`, `VNImageRequestHandler`, and `VNDetectFaceRectanglesRequest` revision 3. The request supplies continuous face yaw, pitch, and roll. Revision 3 is available from macOS 12; older face-detector revisions used discrete pose bins and should not be used for this feature.[^1][^2][^3]

The camera approach supplies information that headphone-only recovery lacks. It remains a proposed engineering solution, not a physically validated fix. Camera visibility, angle accuracy, timing, and stable camera placement must be demonstrated on the actual Mac. If a valid face reference cannot be obtained, clear the desktop effect and retain the original anchor while waiting; do not invent a replacement zero.

## Evidence and the failed headphone-only assumption

The original requirement is a fixed screen-facing direction that survives removal and rewear, including rewear while looking away. Physical testing of the retained-headphone-reference implementation failed this requirement: rewear produced a shifted zero, and switching removal/rewear sides confused the result. This supersedes the earlier assumption that preserving the same manager and copied attitude would be sufficient. It does not establish that every removal or source transition resets Apple's orientation frame.[^4]

A separate recorded diagnostic showed a 32.0-degree quaternion step over 20 milliseconds, above the application's 20.1-degree threshold, while bounding rotation rates were 8.0 and 17.4 degrees per second. Added delivery lag was approximately 23 milliseconds. This is evidence of a measured same-source discontinuity, not proof of its cause. The application's source-change branch separately invalidates the reference and skips comparison of the cross-source pair. These two conditions must remain distinguishable in diagnostics.[^4]

Apple explains that only one earbud supplies motion at a time, that the other can take over after removal, and that this supports a seamless tracking experience. The same WWDC session illustrates retaining a starting attitude. Neither that explanation nor the public `sensorLocation` property defines an error bound or guarantees a persistent numerical reference across all reconnects. Consequently, source identity alone cannot prove that the original frame survived or failed.[^5][^6]

## Why an external reference is necessary

For yaw-only reasoning, let the physical head direction relative to the original screen-facing direction be θ. A headphone stream measures an angle h within a sensor reference, so a simplified model is:

`h = θ + b + measurement error`

Here b is the unknown offset between the headphone frame and the original screen direction. Before removal, calibration estimates b. If b changes while samples are unavailable, one returning measurement contains two unknowns: the physical head turn and the new frame offset. Stillness makes their rates small; it does not determine either absolute value. Saving the last head angle cannot recover an unobserved turn, and integrating rotation rate cannot recover motion for which there are no samples. Gravity constrains tilt but cannot distinguish rotations about vertical. These are consequences of the measurement model.

Suppose the original center was set at the screen, removal occurred while turned left, and rewear occurred while turned right. Both the old orientation and the return orientation can differ from zero. Assigning either one to zero, or adding a constant based only on the last pre-removal sample, is underdetermined. The missing information is a measurement tied to something that did not rotate with the unobserved earbuds.

A camera fixed relative to the display supplies that independent observation. Its face-pose estimate does not depend on the headphone motion manager's arbitrary reference. However, its zero is camera-facing, not automatically screen-facing. The initial calibration therefore records the camera's measured pose while the person deliberately faces the chosen display. This also accommodates a camera mounted above or beside that display, within the method's validated viewing range.

Headphone `heading` and `magneticField` remain diagnostic possibilities rather than the proposed solution. Heading is invalid for arbitrary reference frames, and the headphone manager exposes no selector for requesting magnetic north. The general magnetic-field property does not establish that these AirPods provide useful magnetometer data. A camera anchor does not require those capabilities.[^7]

## Public API implementation surface

| Purpose | Exact public API | macOS applicability and limit |
|---|---|---|
| Capture frames | `AVCaptureSession`, `AVCaptureDeviceInput`, `AVCaptureVideoDataOutput`, `AVCaptureVideoDataOutputSampleBufferDelegate` | Native Mac capture APIs, available before macOS 14. Use video input only. |
| Check/request permission | `AVCaptureDevice.authorizationStatus(for: .video)`, `requestAccess(for: .video, completionHandler:)` | Authorization API available on macOS 10.14+. Check before session setup. |
| Analyze a frame | `VNImageRequestHandler(cvPixelBuffer:orientation:options:)`, `perform(_:)` | Original Vision API available on macOS 10.13+. Supply actual buffer orientation. |
| Estimate head pose | `VNDetectFaceRectanglesRequest`, `revision = VNDetectFaceRectanglesRequestRevision3` | Revision 3 available on macOS 12+. All three pose angles are continuous. |
| Read pose | `VNFaceObservation.yaw`, `.roll`, `.pitch` | Yaw/roll available on macOS 10.14+, pitch on 12+. Values are optional `NSNumber`; do not convert missing values to zero. |
| Inspect landmarks | `VNDetectFaceLandmarksRequest`, `VNFaceLandmarks2D`, `VNFaceLandmarkRegion2D` | Available on macOS 10.13+. Revision 3 supports the 76-point constellation on 10.15+. Optional, not necessary for basic yaw. |
| Compare image quality | `VNDetectFaceCaptureQualityRequest`, `VNFaceObservation.faceCaptureQuality` | Available on macOS 10.15+. Relative image-quality measure, not yaw accuracy in degrees. |
| Associate the camera | `AVCaptureDevice.uniqueID`, `AVCaptureDevice(uniqueID:)` | Device identifier persists on the same system across reconnects, app restarts, and reboots. It does not encode mounting position. |
| Control mirroring | `AVCaptureConnection.automaticallyAdjustsVideoMirroring`, `.isVideoMirroringSupported`, `.isVideoMirrored` | Available on macOS 10.7+. Data-output mirroring changes actual delivered pixels. |
| Observe reframing | `AVCaptureDevice.isCenterStageActive` | Available on macOS 12.3+. Reframing changes the capture geometry; record and validate the mode. |
| Obtain sample timing | `CMSampleBufferGetPresentationTimeStamp(_:)` | Gives the video sample presentation timestamp. Establish its relationship to motion time; do not pair by callback order. |

Apple documents the Vision pose fields, capture/mirroring interfaces, and authorization requirements; local SDK declarations confirm the deployment versions above.[^2][^3][^8][^9][^10][^11] A compile-only Swift 6 probe targeting `arm64-apple-macos14.0` with the installed macOS 26.5 SDK successfully resolved the listed core capture, Vision revision-3, mirroring, camera identity, quality, and Center Stage APIs. No capture session was run during this research. Compilation establishes API availability, not camera quality or runtime permission.

Use the original `VN...` Vision surface for the macOS 14 baseline. Do not silently adopt a newer Swift-only Vision API and thereby raise the deployment requirement. ARKit face tracking is a different platform route intended for supported iPhone/iPad configurations; its face-anchor/world-tracking features are not the native macOS implementation proposed here.[^12]

## The stored reference and recovery calculation

Store two different concepts explicitly. The **screen anchor** is the durable camera-space pose captured while facing the intended display. The **current headphone alignment** maps the current AirPods stream onto that anchor. Reacquisition may replace the headphone alignment while leaving the screen anchor unchanged. This is the essential distinction from the failed automatic-recentering behavior.

For an initial yaw-only prototype, normalize both sensors to the same physical left-positive convention. Define:

- `c0`: robust camera yaw recorded while facing the display during explicit initial setup.
- `c(t)`: camera yaw during a later recovery burst.
- `h(t)`: current headphone yaw within the new stream's frame, paired to the same time.
- `cameraRelative(t) = wrap(c(t) - c0)`.
- `offset = circularEstimate(cameraRelative(t) - h(t))` over accepted paired samples.
- `screenYaw(t) = wrap(h(t) + offset)` during subsequent headphone-only operation.

The wrap operation handles angular boundaries consistently. A circular mean or robust circular estimator is preferable to an ordinary arithmetic average near a wrap boundary. Estimate an offset only from samples within the same confirmed source/frame epoch; restart the candidate burst if the source changes again or another discontinuity occurs.

Example: the stored camera anchor is +5 degrees because of camera placement. On rewear while looking right, the camera measures −30 degrees and the headphone frame reports +10 degrees. The physical screen-relative direction is −35 degrees, so the new alignment offset is −45 degrees. The output remains −35 degrees after recovery; it is not reset to zero. The original +5-degree camera anchor remains unchanged.

If the current application retains its original `CMAttitude` object, the same idea can correct the resulting relative yaw with an external offset. Label that offset separately from the explicit center revision so diagnostics can distinguish “screen anchor changed” from “sensor frame realigned.” Avoid altering a quaternion by guessing component values merely to produce a desired yaw.

Yaw subtraction is a pragmatic approximation for modest pitch and roll. Euler angles do not generally compose by componentwise subtraction. If testing shows coupling errors during nodding or head tilt, compare full rotations after explicitly establishing the camera/headphone axes and rotation order. `VNFaceObservation` supplies Euler values, not a ready-made camera-to-AirPods transform or calibrated 6-DoF face anchor. Do not claim full 3-D fusion from yaw-only offset correction.

## Camera/display identity and geometry

Key each anchor by the explicitly selected physical camera's `uniqueID`, the existing stable display identifier, the processing orientation/mirroring convention, and the request revision. Record the camera format and reframing configuration as diagnostic metadata. Persist only scalar anchor information needed to restore the mapping. Apple's camera identifier survives normal reconnection, but cannot detect that an external camera was rotated, a laptop moved relative to an external display, or a monitor was repositioned.[^9]

An anchor should therefore have a visible “set original direction” action and an explicit invalidation route for physical setup changes. Do not automatically select another camera and apply the old anchor. `systemPreferredCamera` can change spontaneously, including when Continuity Cameras appear; this behavior is useful for general capture but unsuitable for silently retaining a geometric calibration.[^13]

An integrated laptop camera is a good initial configuration because its mounting relationship to the laptop display is mechanically stable. With an external display, define which physical screen establishes zero and calibrate that pair. Multiple independently oriented displays require separate anchors if each display needs its own center; the existing policy of applying one head direction to several displays can instead keep one explicit reference display.

An anchor defined by head orientation is not identical to eye gaze toward a screen point. Moving the chair sideways, leaning, changing distance, and turning the eyes without the head may affect the relationship between face yaw and perceived screen-facing behavior. Validate the intended seated working area. Bounding-box position and scale can be useful rejection cues for a large seating change, but are not a calibrated 3-D head-position measurement.

Center Stage automatically pans and changes field of view.[^14] Camera tilt, auto-framing, digital crops, lens distortion, and mirroring can change the estimator's inputs. Prefer a stable capture configuration and treat configuration changes as reasons to validate the anchor. Do not silently change a person's global camera effects. If those effects cannot be held constant, include them in the test envelope rather than asserting that a persistent device ID solves geometry.

## Orientation, mirroring, and angle signs

`VNFaceObservation.yaw` represents rotation about the image's y axis in radians; it is optional. The local header specifies a positive counterclockwise convention and approximately ±π/2 range. Those definitions alone do not establish which sign the app should label physical left after the capture pipeline's orientation transforms. Confirm left/right with a controlled movement.[^2][^3]

Prefer unmirrored analysis pixels. Where supported, disable automatic mirroring and set the analysis connection to unmirrored. A user-facing selfie preview can be mirrored separately. Apple explicitly states that `AVCaptureVideoDataOutput` mirrors delivered frames when its connection is mirrored; accounting for mirroring twice would reverse the result.[^10]

Pass the real image orientation to `VNImageRequestHandler`. Its explicit EXIF orientation overrides other orientation information. Do not copy an iPhone front-camera `.leftMirrored` convention into a Mac capture pipeline. Test saved upright/mirrored/rotated fixtures before live camera testing. Vision image rectangles use normalized coordinates with a lower-left origin; convert them deliberately if drawing overlays in another coordinate system.[^3][^15]

## Acceptance of a camera observation

A face detector finding a face does not prove that it found the AirPods wearer or that its yaw estimate is accurate enough to correct a privacy effect. Accept a recovery burst only when a consistent face is visible, pose values are finite, the face is sufficiently large, and multiple time-aligned estimates agree. Reject multiple plausible faces rather than selecting whichever happens to be first in the result array. Face-box tracking can associate observations within a burst; it does not authenticate identity across an absence.[^16]

Vision's `confidence` is not a calibrated yaw-error bound. Apple notes that a value of 1 can even indicate an observation that does not assign meaning to confidence. Face capture quality compares lighting, sharpness, positioning and related image attributes for the same subject; it is not a universal threshold for a correct angle.[^17][^18] Use both, if useful, alongside temporal consistency and measured task-specific performance. Do not require a nearly frontal face merely because frontal captures receive higher quality scores: that would defeat recovery while looking away.

Landmarks are optional supporting evidence. The 76-point constellation includes facial features and per-point precision estimates, but its 2-D points do not by themselves supply a calibrated 3-D head pose. A custom landmark/PnP method would need a face model, camera intrinsics, distortion handling, and separate validation. Start with revision-3 yaw; add landmarks only when they resolve a demonstrated failure such as unstable face association or severe occlusion.[^3]

Prototype acceptance thresholds should be measured, not represented as Apple guarantees. A reasonable experimental starting point is 5–10 accepted paired observations over approximately 0.5–1 second after usable frames appear, with a bounded overall attempt of roughly 3 seconds. Evaluate robust residual spread, pitch/roll limits, face size, and synchronization error. These are proposed tuning values. If the person is moving rapidly, either align timestamps accurately or wait for a brief stable interval at the current turned pose; stability must not redefine the screen anchor.

## Synchronization and lifecycle

Capture timestamps represent image acquisition timing more usefully than the time Vision finishes. Keep a short bounded buffer of headphone samples and associate a frame with the nearest or interpolated headphone pose at its acquisition time. Establish the clock relationship rather than assuming raw video, headphone, and receipt timestamps share an epoch. Store receipt time and processing duration as separate diagnostics.[^11]

On macOS 12.3+, `AVCaptureSession.synchronizationClock` explicitly identifies the clock used by all capture-output sample timestamps. Convert camera PTS with `CMSyncConvertTime(pts, from: session.synchronizationClock, to: CMClockGetHostTimeClock())`; reject invalid conversion results. This converts the camera time only. No headphone-specific public guarantee was established that identifies the remote AirPods timestamp epoch as the Mac host clock. The prototype must therefore use the agreed bounded low-motion overlap policy, with roughly 0.8–1 second of stable camera and headphone observations, rather than presenting receipt-time alignment as exact hardware synchronization.[^24]

The engineering error is material: pairing a face image with an AirPods sample 100 milliseconds later during a 90-degree-per-second head turn can introduce approximately 9 degrees of alignment error. A stationary pairing burst reduces this error without requiring the wearer to face forward. Use a fixed-size buffer and abandon stale candidates rather than allowing a queued image to correct a later sensor epoch.

Use a serialized capture-session owner for configuration and start/stop. `startRunning()` and `stopRunning()` are synchronous and can block; keep them off the UI/render actor.[^19] Deliver observations onto the model with an immutable recovery generation. Manual pause, shutdown, session inactivity, camera change, anchor replacement, a new disconnect, or a newer correction attempt must invalidate older work. Recheck that generation after permission callbacks, session startup, Vision processing, and before committing the correction or resuming desktop capture.

A suitable flow is: pause/clear effect; await fresh headphone samples and an active Mac session; start a bounded camera burst; collect matching valid observations; commit one headphone alignment against the unchanged screen anchor; stop the camera; resume only if prior active intent still exists. If the attempt times out or fails, stop the camera and stay recoverable. Repeat attempts need bounded backoff or an explicit retry, not a tight loop with the camera continually active. Out-of-ear motion alone must not trigger camera activity while the login session or displays are inactive.

Observe capture runtime errors, interruptions, and device disconnection. A configured session is not proof of incoming frames, and permission is not proof that another app, a shutter, lighting, or the camera hardware allows usable images. Keep correction validity separate from permission, session-running state, face presence, headphone freshness, and screen-capture readiness.

## Sparse bursts compared with continuous capture

| Strategy | Benefit | Limitation | Recommended role |
|---|---|---|---|
| Camera only during reconnect/jump recovery | Camera normally off; independent origin at interruption boundaries | Startup latency; cannot correct unobserved slow drift between bursts | Initial implementation |
| Periodic camera bursts | Can check slower drift while reducing camera duty cycle | Repeated startup, visible activation, additional energy; interval leaves blind periods | Later option if drift is measured |
| Continuous low-rate face analysis with camera running | Frequent external orientation checks | Camera remains active even if Vision runs rarely; continual visibility/energy/privacy cost | Explicit optional mode if sparse approach is insufficient |
| Camera-only direction | Independent of AirPods frame changes | Greater sensitivity to visibility, profile, image latency and pose noise | Diagnostic comparison, not first default |

Apple recommends keeping capture sessions running only while needed, stopping at the earliest opportunity, and choosing the lowest image quality that meets the feature's needs.[^20] Processing one image per second while leaving a 30-fps session running is not equivalent to turning the camera off. Sparse capture should end the session after a successful or failed bounded attempt. Keep configuration reusable if useful, but do not leave acquisition active merely to avoid startup costs.

Begin by measuring a modest supported format, such as 640×480 or 1280×720 where available. Choose supported frame-rate ranges under `lockForConfiguration`; do not assign an unsupported rate. A 10–15-fps analysis target is an experiment, not a promise that every camera supports such capture rates. Drop unnecessary frames rather than queueing them, use `alwaysDiscardsLateVideoFrames = true`, and allow at most one pending Vision analysis.[^21] Compare camera startup-to-first-valid-pose latency, recovery latency, CPU/GPU activity, and battery impact on this Mac.

Sparse event-driven capture cannot guarantee correction of slow headphone drift while the camera is off. Likewise, an orientation reset too small to trigger the motion heuristic may remain undetected until the next burst. These are meaningful product tradeoffs. A claim of continuously camera-verified direction would require continuous or sufficiently frequent observation, not merely a retained calibration.

## Local processing and permission boundary

Vision supports processing camera buffers within the app; the proposed design requires no server, remote model, video upload, or cloud account. Apple's documentation describes Vision processing as occurring on the device.[^22] Keep images in volatile buffers only, release them after analysis, and persist only the camera/display anchor and a few non-image diagnostics. Do not add movie output, photo saving, face embeddings, identity recognition, or a microphone input for this feature.

Add a clear `NSCameraUsageDescription`, check camera authorization, and request access through the public API when the person enables camera-assisted recovery. Apps using App Sandbox or Hardened Runtime need the appropriate camera entitlement, `com.apple.security.device.camera`. The entitlement and consent are separate requirements; neither should be bypassed or reset automatically.[^8][^23] A proposed explanation is: “AirVeil briefly uses your camera to restore your original screen-facing direction after AirPods reconnect. Images stay on this Mac and are not saved.” This wording must match the implementation's actual lifetime and storage behavior.

The camera indicator may be visible during each burst. Turning off preview does not turn off capture, and another app can keep a camera active after this app stops. Test session shutdown and resource release directly rather than interpreting the shared indicator alone. Permission denial must leave the existing manual-center workflow available without triggering repeated prompts.

## Validation and acceptance

Separate deterministic software checks from physical camera accuracy. Successful compilation and synthetic angle tests cannot establish the latter.

| Test | Required observable result |
|---|---|
| Original setup | Record an immutable camera anchor while deliberately facing the selected screen; distinguish anchor revision from headphone-alignment revision. |
| Rewear looking left/right | Test at several visible nonzero turns. Correction preserves that turn and returning to the original direction restores zero without Set center. |
| Removal at one turn, rewear at the opposite turn | Both left→right and right→left retain the original screen reference; neither removal pose nor return pose becomes zero. |
| Source handoff | Exercise left/right source changes and both insertion orders. Camera candidate samples never span incompatible headphone epochs. |
| Held turn | Hold a visible left/right turn through correction. Output remains turned for at least several seconds after camera shutdown. |
| Same-source reset/jump | Synthetic discontinuity triggers one recovery attempt; a physical observed event uses unchanged camera anchor. No repeated correction loop. |
| Sign and orientation | Fixed fixtures and physical left/right test agree for analysis orientation, mirrored preview, and supported camera mounting orientations. |
| Pose range | Measure direction/error across 0°, ±15°, ±30°, ±45° and larger visible turns where practical, plus nodding/roll. Document the range that passes. |
| Poor visibility | Closed shutter, darkness, glasses glare, partial face, out-of-frame, extreme profile, and multiple faces produce no invented alignment. |
| Geometry changes | Different camera ID, moved external camera/display, laptop repositioning and Center Stage changes cannot silently reuse an incompatible anchor. |
| Timing and delays | Inject delayed frames, long Vision processing, reordered callbacks, and different clocks. Stale data cannot commit a new alignment. |
| Lifecycle races | Pause/quit/sleep/new disconnect during permission, session startup, or processing cancels correction and automatic resume; camera stops. |
| Camera availability | Permission denied/revoked, unplug, interruption and camera contention produce a bounded failure with no prompt loop. |
| Energy and privacy | Normal tracking leaves this app's camera session stopped; each attempt has a bounded duration; no image files/network requests/microphone activation occur. |

For the initial experiment, use repeated physical postures and report median, upper-percentile, and worst observed original-zero error rather than selecting one favorable return. A provisional engineering target is recovery within approximately 3 seconds of an observable stable pose, with zero error comfortably smaller than the configured blur-onset angle. For example, an onset near 10 degrees calls for an error budget materially below 10 degrees; a 3–5-degree target is an experimental acceptance target, not established Vision accuracy. Re-evaluate sign and angle performance across people and camera/lighting configurations before generalizing beyond this workstation.

Successful recovery must simultaneously satisfy the physical reference test, remain responsive during normal AirPods tracking, release the camera, and preserve manual pause/recovery controls. If accuracy does not meet the chosen threshold, the next step is measured improvement of the camera estimator or capture geometry. Reintroducing “current still pose equals center” would hide the failure while violating the original requirement.

## Selected optional prototype

The selected optional prototype uses a lower analysis rate than the earlier exploratory values: at most 3 analyzed frames per second at a requested 640×480 capture preset, with an attempt lasting no more than 12 seconds including startup (up to 20 seconds for explicit initial setup). Capture requests 3 fps where the device supports it, otherwise the nearest supported low rate. Initial physical-sign calibration observes a brief deliberate turn after explicit screen-facing setup within the same inertial epoch. Automatic recovery only accepts a stable turned pose against the existing camera anchor; it never changes that anchor or renews camera use indefinitely. These are prototype engineering choices, not measured performance claims.

## Sources

[^1]: Apple, [Detect people, faces, and poses using Vision](https://developer.apple.com/videos/play/wwdc2021/10040/), WWDC21. Revision 3 adds pitch and continuous pose metrics; explains face-quality limitations.
[^2]: Apple, [VNFaceObservation](https://developer.apple.com/documentation/vision/vnfaceobservation) and [yaw](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw), current documentation, accessed September 13, 2026. Optional pose outputs and axes.
[^3]: Apple macOS 26.5 SDK, local headers `Vision.framework/Headers/VNObservation.h`, `VNDetectFaceRectanglesRequest.h`, `VNDetectFaceLandmarksRequest.h`, `VNFaceLandmarks.h`, and `VNRequestHandler.h`, under `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/`. Platform availability, revision behavior, angles, image orientation and landmark precision. Apple [Applying Matte Effects to People in Images and Video](https://developer.apple.com/documentation/vision/applying-matte-effects-to-people-in-images-and-video) independently demonstrates selecting face detector revision 3.
[^4]: AirVeil project, `validation/STATUS.md`, build 7 observation paragraph recording 32.0° step, 20.1° threshold and later explicit center revision 4→5; current `Sources/MotionService.swift` source/jump branches. Subsequent direct physical-test feedback in this project session reports shifted zero after removal and inconsistent opposite-side rewear. This later feedback supersedes the document's earlier unconfirmed physical acceptance status; it is local evidence, not a published Apple finding.
[^5]: Apple, [What's new in Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179/), WWDC23. Starting pose, source earbud handoff, out-of-ear connection events.
[^6]: Apple, [sensorLocation](https://developer.apple.com/documentation/coremotion/cmdevicemotion/sensorlocation-swift.property), current documentation, accessed September 13, 2026. Origin of device-motion data.
[^7]: Apple, [heading](https://developer.apple.com/documentation/coremotion/cmdevicemotion/heading), [magneticField](https://developer.apple.com/documentation/coremotion/cmdevicemotion/magneticfield), and [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager), current documentation; local Core Motion headers. Reference restrictions and headphone public API surface.
[^8]: Apple, [Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos) and [authorizationStatus(for:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)), current documentation, accessed September 13, 2026.
[^9]: Apple, [uniqueID](https://developer.apple.com/documentation/avfoundation/avcapturedevice/uniqueid), current documentation. Same-system persistence of physical capture-device identifiers.
[^10]: Apple, [isVideoMirrored](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/isvideomirrored) and [automaticallyAdjustsVideoMirroring](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/automaticallyadjustsvideomirroring), current documentation. Pixel mirroring and automatic changes.
[^11]: Apple, [CMSampleBufferGetPresentationTimeStamp](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetpresentationtimestamp(_:)), current documentation. Sample presentation timestamps.
[^12]: Apple, [ARFaceTrackingConfiguration](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration), current documentation. Supported iOS/iPadOS face tracking and face-anchor capabilities.
[^13]: Apple, [systemPreferredCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempreferredcamera), current documentation. Automatic device-selection changes and manual selection considerations.
[^14]: Apple, [isCenterStageActive](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageactive), current documentation. Automatic panning and changing field of view.
[^15]: Apple, [Vision](https://developer.apple.com/documentation/vision) and [regionOfInterest](https://developer.apple.com/documentation/vision/vnimagebasedrequest/regionofinterest), current documentation. Image coordinate system and normalized regions.
[^16]: Apple, [VNTrackObjectRequest](https://developer.apple.com/documentation/vision/vntrackobjectrequest) and [Tracking the User's Face in Real Time](https://developer.apple.com/documentation/vision/tracking-the-user-s-face-in-real-time), current documentation. Tracking observations across images; the sample itself targets iOS and must not be copied as a Mac app unchanged.
[^17]: Apple, [confidence](https://developer.apple.com/documentation/vision/vnobservation/confidence), current documentation. Meaning and limits of observation confidence.
[^18]: Apple, [faceCaptureQuality](https://developer.apple.com/documentation/vision/vnfaceobservation/facecapturequality-bjg5), current documentation. Comparative lighting, blur and positioning score.
[^19]: Apple, [startRunning()](https://developer.apple.com/documentation/avfoundation/avcapturesession/startrunning()) and [stopRunning()](https://developer.apple.com/documentation/avfoundation/avcapturesession/stoprunning()), current documentation. Synchronous capture lifecycle.
[^20]: Apple, [Reducing power usage when capturing media](https://developer.apple.com/documentation/xcode/reducing-power-usage-when-capturing-media), current documentation. Camera duty cycle and format selection.
[^21]: Apple, [Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html), Technical Note TN2445, July 12, 2017; current [alwaysDiscardsLateVideoFrames](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes). Bounded queues, frame drops, and supported frame rates.
[^22]: Apple, [Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images), current documentation. States that Vision processing occurs on-device; the proposed face implementation uses local pixel-buffer requests and adds no network path.
[^23]: Apple, [Camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera) and [NSCameraUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription), current documentation. Hardened Runtime/App Sandbox camera capability and usage description.
[^24]: Apple, [synchronizationClock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock) and [CMSyncConvertTime](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:)), current documentation and macOS 26.5 `AVCaptureSession.h`. Capture-output clock semantics and explicit conversion between clocks.
