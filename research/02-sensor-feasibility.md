# AirPods head tracking feasibility and calibration

## Decision

A native macOS app can use public Core Motion APIs to receive AirPods head orientation and drive an opposite-side screen effect. Apple introduced `CMHeadphoneMotionManager` on macOS 14; the same interface had been available on iOS and iPadOS since version 14. Apple's WWDC presentation explicitly identifies AirPods Pro and other headphones with dynamic head tracking as supported sources.[^1] AirPods Pro 3 specifications confirm dynamic head tracking, a motion-detecting accelerometer, and the H2 chip.[^2]

The proposed feature should be described as **head-controlled screen obscuring**. AirPods report headphone motion; this is neither eye tracking nor a measurement of bystanders. The software changes the displayed pixels for everyone. It cannot make the right half unreadable only to a right-side observer while leaving the same half clear to its owner. That limitation follows from the proposed single composited image, independently of sensor quality.

Implement macOS first in Swift, with a small Core Motion service feeding a separate display renderer. Preserve future iPhone/iPad work as an explicit platform track: those devices support sensor input, but current public interfaces do not establish a general-purpose overlay capable of modifying every other app's screen. An in-app reader or browser could support the effect within its own content; it would not satisfy a system-wide mobile privacy requirement.[^3]

## Evidence and its limits

This assessment was checked on September 13, 2026. The development Mac reports macOS 26.6.2, build 25G83, and the installed command-line macOS SDK reports 27.0. That SDK contains `CMHeadphoneMotionManager`, its delegate, `CMDeviceMotion`, `CMAttitude`, and `CMLogItem`. The manager and delegate declare availability from macOS 14.0. These are verified local API declarations, not a physical AirPods test.[^4]

| Requirement | Evidence | Confidence / remaining work |
|---|---|---|
| Public headphone motion access on Mac | WWDC23 and local SDK declarations | Confirmed platform capability |
| AirPods Pro 3 has dynamic head tracking | Apple product specification | Confirmed product feature; actual streaming still needs runtime test |
| Attitude relative to a saved starting pose | Apple sample strategy and `multiply(byInverseOf:)` | Confirmed method; physical axis/sign validation pending |
| Motion stream is already relative to the Mac display | No documented screen-reference contract found | Do not assume |
| Configurable 60 Hz / 100 Hz AirPods updates | No such property on headphone manager | Unsupported claim; measure actual cadence |
| Continuous drift-free calibrated yaw | No guarantee found | Needs sustained physical tests |
| Blur conceals information reliably | No physical readability tests yet | Blur strength must be tested; opaque masking is stronger |
| System-wide mobile version | Sensor API exists, arbitrary cross-app overlay route unproven | Not an established deliverable on stock iOS/iPadOS |

## Sensor model and practical access

Core Motion's processed device-motion representation provides attitude, rotation rate, gravity, and user acceleration. Its general documentation explains how sensor fusion separates gravity from acceleration caused by movement.[^5] For this app, use the fused attitude as the main orientation signal. Integrating rotation rate indefinitely would add error; acceleration alone does not supply a dependable left-versus-right heading estimate.

Apple's Pro 3 retail specification does not list a separate gyroscope entry. Do not turn that omission into a claim that the product lacks rotational sensing, or invent a chip-level sensor model. The implementation depends on the public attitude stream, not a reverse-engineered AirPods sensor part number. The public motion service is stronger implementation evidence than assumptions about the marketing sensor list.[^1][^2]

The SDK establishes the following practical API surface:[^4]

- `authorizationStatus()` reports headphone-motion authorization.
- `isDeviceMotionAvailable` checks availability before starting.
- `startDeviceMotionUpdates(to:withHandler:)` provides pushed samples on an operation queue.
- `startDeviceMotionUpdates()` plus `deviceMotion` supports pulling the latest sample.
- `stopDeviceMotionUpdates()` ends the stream.
- `startConnectionStatusUpdates()` and `stopConnectionStatusUpdates()` provide separate connection monitoring in the current SDK.
- `CMHeadphoneMotionManagerDelegate` receives connection and disconnection events. Its callbacks run on the motion queue, or on the main thread when no queue was specified.

Keep the manager alive as a service owned by the application. Handle its data off the main UI thread, copying only the latest validated orientation and status across to the renderer. A queue containing every historical pose is counterproductive for a visual effect: if rendering falls behind, the screen must catch up to the present instead of replaying old head motion.

The app must include `NSMotionUsageDescription` in its Info.plist. Apple's manager documentation says that omitting this key crashes an iOS or macOS app when motion updates start.[^6] The purpose string can plainly explain that head movement controls which side of the display is obscured. Motion permission and screen-capture permission are separate capabilities; a successful motion grant proves nothing about desktop capture.

One sample comes from one earbud at a time. `CMDeviceMotion.sensorLocation` identifies left or right; it is a property of the sample, not the manager. Apple explains that removing the active bud with Automatic Ear Detection enabled can transfer streaming to the other bud.[^1] The app should retain the active source in diagnostics and mark any handoff in test results, rather than requiring a particular earbud.

## Reference frame, yaw, and calibration

`CMAttitude` supplies Euler angles, a rotation matrix, and a quaternion. The SDK defines Euler angles in radians and provides `multiply(byInverseOf:)` to calculate a change relative to another attitude.[^7] A neutral-pose capture must copy the original attitude; applying a mutating relative transformation to an object used later as the baseline would corrupt calibration.

For a seated person facing a fixed screen, adopt this explicit contract:

1. The person looks comfortably at the center of the target display and selects **Set center**.
2. The app waits for fresh, stable samples and stores a baseline attitude.
3. Each valid sample is compared with that baseline.
4. Turning physically left increases right-side coverage; physically right increases left-side coverage.
5. Returning inside a dead zone restores the clear display.

The headphone manager does not expose `attitudeReferenceFrame`, a `using:` reference-frame argument, or a `deviceMotionUpdateInterval` setter in the inspected SDK.[^4] General Core Motion documentation discusses configurable frames and frequencies for **CMMotionManager**. Those examples must not be copied as if they were headphone-manager features.[^8] Similarly, creating an unrelated CMMotionManager instance does not establish that its chosen frame controls AirPods: no headphone-specific contract supporting that approach was verified.

A direct wrapped yaw difference is useful for an initial upright demonstration:

`delta = atan2(sin(yaw - centerYaw), cos(yaw - centerYaw))`

This prevents a transition across ±π from producing an artificial full-turn jump. It is an engineering proposal, not an Apple calibration guarantee. A relative quaternion/attitude calculation is preferable when pitch and roll can vary substantially. Whatever representation is selected, test head turns while looking slightly up/down and while leaning, because a mathematically valid Euler decomposition can still be an awkward proxy for the intended horizontal turn.

Do not hard-code an untested physical sign from the words “positive yaw.” Coordinate handedness, quaternion conventions, rendering coordinates, and accidental view mirroring can reverse the behavior. The product acceptance criterion is anatomical: left head turn must obscure the right side of the physical display. Run a short setup confirmation with an obvious labeled preview and retain an **Invert direction** control. That control is a useful recovery path; it is not a substitute for verifying the default.

Calibration aligns the head with a chosen starting pose, not with a tracked laptop position. Moving the MacBook or rotating the chair changes the physical relationship. An easy **Set center** action is therefore a requirement. Do not silently recenter merely because the head has held still: a person may deliberately keep looking left, and automatic recentering would clear the very side that should stay obscured.

## Recentring and audio interaction risk

A recent developer's first-person report on Apple's forum says yaw appears to recenter when playback begins with Spatial Audio in either Fixed or Head Tracked mode. At inspection it had no replies and no Apple confirmation.[^9] This is evidence of a reported failure mode, not proof that every AirPods Pro 3/firmware combination behaves that way.

The application should nevertheless test this scenario before declaring the feature reliable. Collect orientation samples before, during, and after playback starts in another app. A discontinuity that is inconsistent with recent rotation-rate samples is a reason to mark calibration uncertain and request recentering; it is not a reason to silently adopt the new pose as neutral. Any automatic compensation algorithm would need separate validation.

Other required reference-integrity tests include removing one bud, removing both, replacing them, routing audio to a different device, reconnecting Bluetooth, and waking the Mac. When a discontinuity or stale stream occurs while protection is active, the app should visibly report the loss of tracking. A privacy-oriented default can retain coverage or obscure both sides until the person chooses to resume. The exact fail state should be explicit, because retaining only the old half cannot protect against a subsequent unknown head turn.

## Timing and animation

The inspected headphone API offers no caller-selected sample interval.[^4] Apple's generic examples mentioning 50, 60, or 100 Hz relate to other motion managers; they are not a promised AirPods sample rate.[^8] Report measured rate, jitter, maximum gap, and latency on this Mac with these AirPods and this firmware.

Every motion object inherits a timestamp. The local header defines it in relation to Mach absolute time.[^10] Track both sensor timestamp and receipt time. Successive source timestamps reveal cadence and duplicates; monotonic receipt times identify stalls in the application path. Before interpreting their difference as transport latency, establish the timestamp epoch and scaling empirically for the specific runtime.

Smooth rendering can run at the display's cadence even if sensors arrive less often. Use the latest valid target value and a short frame-time-aware low-pass response, rather than animating each sample over a long independent duration. As an initial tuning proposal, use an 8–12 degree neutral zone, reach strong coverage around 30–40 degrees, and try approximately 80–150 ms response smoothing. These are usability starting points, not researched hardware specifications or privacy guarantees.

For opposite-side mapping, separate direction from magnitude. Compute a normalized absolute turn after the dead zone, apply a bounded easing curve such as smoothstep, and drive only the opposite side. Test the transition through center and a rapid reversal: neither side should flicker, and an old animation must not keep exposing a side after the newest pose requires coverage. Consider increasing protection faster than revealing content again.

Measure end-to-end visual response, not just the frame rate. For example, collect a camera view of a deliberate head turn and the display or use an instrumented controlled sample sequence for the renderer. Simulated samples prove the mapping and animation code path, while a physical recording is needed to assess true sensing and display delay. No physical timing measurement has been performed in this report.

## Privacy behavior and honest product scope

Software blur is an obscuration effect, not an optical privacy filter. It obscures the same pixels for the owner and everyone else. A right-side observer can still view the unmasked left half from an angle, so opposite-half masking cannot establish the claim that the whole computer becomes private when the owner turns away.

Blur also preserves broad shapes, colors, image layout, and potentially large text. A partially transparent overlay can expose original content underneath even when the overlay image looks heavily blurred. Privacy validation must therefore use actual documents containing small and large text, high-contrast content, faces, and moving material. A full-opacity covered region with a sufficiently blurred captured frame is better than blending clear source pixels into it; an opaque dark mask provides a stronger concealment option when content secrecy matters more than appearance.

Recommended product controls are **Pause**, **Set center**, **Invert direction**, **Sensitivity**, **Blur / opaque cover**, and an always-reachable emergency reveal action. The app should label capture or tracking failures in plain language and never report “protected” just because its process is running. Screen lock and secure system surfaces are outside the proof of a normal desktop overlay unless independently tested.

A fully local design requires no camera, microphone, heart-rate readings, or server upload to implement the stated head-turn behavior. Store preference values and calibration settings if useful; do not persist raw screen captures or a continuous motion history by default. The proposed sensor service can operate independently of any cloud service.

## iPhone and iPad track

Apple Platform Security states that third-party iOS/iPadOS apps are sandboxed and may reach beyond their own data only through services explicitly supplied by the system.[^3] No general public API authorizing arbitrary cross-app visual modification was established here. Screen recording or ReplayKit capture does not by itself grant the ability to place a controllable blur above every app.

Continuous operation adds a separate limitation. In an August 2026 Apple Developer Forum response, Apple DTS explains that Core Motion does not supply a background-execution mechanism. Apps must qualify for another actual user-facing background activity; selecting location or audio simply to keep a motion feature alive is not the intended route.[^11]

Consequently the supported mobile design to investigate is an app-owned content surface, potentially sharing calibration and mapping logic with macOS. A system-wide mobile version remains an unmet original aspiration and should be tracked openly rather than represented as already supported. A phone acting as a head-motion relay to the Mac would not overcome mobile background limits automatically and is unnecessary for a Mac that can receive the headphones directly.

## Physical acceptance protocol

Before declaring the Mac app complete, collect evidence for these cases:

| Test | Required observation |
|---|---|
| Permission accepted / denied | Clear status, no crash, no misleading active protection |
| Both buds worn and Mac connected | Fresh motion samples, changing attitude, source reported |
| Neutral capture | Center established only from valid stable samples |
| Left 15°, 30°, 45° | Increasing right-side coverage |
| Right 15°, 30°, 45° | Increasing left-side coverage |
| Return to center | Predictable release without flicker |
| Hold left/right for 60 seconds | Coverage stays active; no silent recenter |
| Five-minute neutral / turning sequence | Drift and false-trigger rate measured |
| Tilt head / look up or down | Horizontal mapping remains usable |
| Remove active bud / both buds | Handoff or loss displayed; chosen fail state occurs |
| Start/stop Spatial Audio elsewhere | Any reference reset detected; no false safety claim |
| Sleep/wake and reconnect | Stream freshness revalidated and center restored explicitly |
| Mac or seating position moved | Recenter is available and works |
| Busy CPU/GPU / display refresh change | No old-sample replay; timing remains acceptable |
| Actual text readability | Covered region tested from plausible observer positions |

Record macOS version, AirPods model and firmware, sample counts/rate, maximum stale interval, active sensor location, calibration procedure, and whether each result came from physical hardware or simulation. Avoid publishing identifying device serial numbers or personal screen contents in test artifacts.

## Sources

[^1]: Apple, [What’s new in Core Motion, WWDC23 session 10179](https://developer.apple.com/videos/play/wwdc2023/10179/), 2023. Headphone-motion section; platform availability, supported source class, reference-pose sample, earbud handoff.
[^2]: Apple Support, [AirPods Pro 3 — Tech Specs](https://support.apple.com/en-au/125135), product introduced 2025; accessed September 13, 2026. Product sensors, H2, dynamic head tracking.
[^3]: Apple Platform Security, [Security of runtime process in iOS, iPadOS and visionOS](https://support.apple.com/en-ie/guide/security/sec15bfe098e/web), December 19, 2024. Sandbox and system-service boundary; mobile overlay conclusion is an architectural inference.
[^4]: Apple, installed macOS SDK 27.0, `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/CMHeadphoneMotionManager.h`, `CMHeadphoneMotionManagerDelegate.h`, and `CMDeviceMotion.h`; inspected September 13, 2026. Local primary source, no public URL. Runtime macOS version checked using `sw_vers`, SDK using `xcrun --sdk macosx --show-sdk-version`.
[^5]: Apple Developer Documentation, [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion), accessed September 13, 2026. Processed attitude, rotation, and acceleration representation.
[^6]: Apple Developer Documentation, [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager), accessed September 13, 2026. Availability check and required motion purpose key.
[^7]: Apple Developer Documentation, [CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude) and [multiply(byInverseOf:)](https://developer.apple.com/documentation/coremotion/cmattitude/multiply(byinverseof:)); installed `CMAttitude.h`, accessed September 13, 2026. Relative attitude and mathematical representations.
[^8]: Apple Developer Documentation, [Getting processed device-motion data](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data) and [CMAttitudeReferenceFrame](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe), accessed September 13, 2026. General examples are scoped to CMMotionManager; headphone-specific availability verified against [^4].
[^9]: Ahmed_Mohamed, [CMHeadphoneMotionManager yaw jumps when Spatial Audio becomes active](https://developer.apple.com/forums/thread/844940), Apple Developer Forums, displayed as created six days before September 13, 2026. First-person developer report; no replies or Apple confirmation at inspection.
[^10]: Apple, installed macOS SDK 27.0 `CoreMotion.framework/Headers/CMLogItem.h`; [timestamp API](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp), accessed September 13, 2026. Local header is the direct evidence for the timestamp wording.
[^11]: Kevin Elliott, Apple DTS Engineer, [Does background CMDeviceMotion delivery depend on an active Core Location session?](https://developer.apple.com/forums/thread/841001), August 2026. Apple staff explanations of suspension, background categories, and Core Motion limitations; accessed September 13, 2026.
