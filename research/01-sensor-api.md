# AirPods head motion for directional screen privacy

## Decision

A native macOS app can obtain AirPods head motion through Apple's public `CMHeadphoneMotionManager` API on macOS 14 and later. There is no requirement to relay motion through an iPhone, use Mac Catalyst, implement a Bluetooth protocol, or inspect private frameworks. Apple's WWDC23 session explicitly introduced native Mac support, and both current documentation metadata and the installed SDK confirm the macOS 14 minimum.[1][2][3]

Use Swift with a small Core Motion service that publishes calibrated head orientation to the desktop renderer. A separate pure Swift transformation layer should convert orientation into left/right coverage. Keep motion acquisition independent of rendering so simulated input can validate animation without being mistaken for hardware verification. Full desktop composition is a separate platform capability: the existence of this sensor API on iOS/iPadOS does not establish permission to obscure other apps there.

The evidence supports proceeding with implementation. It does **not** yet establish that the particular AirPods Pro 3 pair attached to this Mac delivers stable, correctly signed measurements, or that the final visual obscuration prevents reading. Those require on-device acceptance checks.

## Hardware and signal meaning

Apple lists a motion-detecting accelerometer, a speech-detecting accelerometer, a skin sensor, a workout heart-rate sensor, and touch controls for AirPods Pro 3. The product supports Spatial Audio with dynamic head tracking and uses Apple's H2 headphone chip. These are distinct features: heart-rate sensing and microphone access are not prerequisites for measuring head pose.[4]

The public software contract is processed device motion. Apple describes `CMDeviceMotion` as exposing orientation, rotation rate, gravity, and user acceleration. Its general processing explanation describes fusing gyroscope and accelerometer information to separate gravity from movement. A consumer specification's omission of an explicitly named gyroscope is therefore not evidence that head orientation is unavailable. Conversely, this report does not infer an unpublished Pro 3 inertial-chip model, sample frequency, magnetometer, accuracy bound, or hardware synchronization guarantee.[5]

Apple says headphone motion streams from head-tracking-capable audio products and that only one bud supplies the stream at a time. `sensorLocation` identifies the supplying bud; removal of that bud can transfer the stream to the other one. With Automatic Ear Detection enabled, removing and replacing the earbuds also produces connection events.[1]

The API measures **head orientation**, not eye gaze, the location of another person, their viewing angle, or the display's pose in the room. The feature can respond to a deliberate head turn; it cannot prove who is looking at the screen. A software blur alters pixels visible to everyone. It does not provide the optical direction selectivity of a physical privacy filter. These are consequences of the measurement and display model, not additional sensor claims.

## Verified platform and API surface

The local Command Line Tools SDK identifies itself as macOS 27.0. Its `CMHeadphoneMotionManager.h` and delegate header mark both types as available on macOS 14.0, iOS 14.0, and watchOS 7.0, and unavailable on visionOS and tvOS. Apple's documentation also lists iPadOS 14 and Mac Catalyst 14.[2][3]

| Capability | Native Mac status | Design consequence |
|---|---|---|
| `CMHeadphoneMotionManager()` | macOS 14+ | Native AppKit/SwiftUI application is appropriate. |
| `authorizationStatus()` | Available | Distinguish undetermined, authorized, denied, and restricted. |
| `isDeviceMotionAvailable` | Available | Check hardware/service availability before starting. |
| `isDeviceMotionActive` | Available | Diagnostic state; not proof that recent frames are arriving. |
| Push `startDeviceMotionUpdates(to:withHandler:)` | Available | Process samples on a serial operation queue. |
| Pull `startDeviceMotionUpdates()` and `deviceMotion` | Available | Useful for a consumer that already polls; push is simpler here. |
| Connection delegate and explicit connection-status updates | Available | Monitor arrival, removal, and reconnection independently. |
| `CMDeviceMotion.sensorLocation` | Available | Observe left/right source changes. |
| Attitude quaternion, rotation matrix, yaw/pitch/roll | Available | Use attitude relative to explicit neutral calibration. |
| `deviceMotionUpdateInterval` on the headphone manager | **Not present** | Do not copy this member from `CMMotionManager` examples. |
| `startDeviceMotionUpdates(using:...)` on headphone manager | **Not present** | No per-start selectable reference-frame overload. |
| Headphone reset/recenter method | **Not present** | Implement reference calibration in the app. |
| Raw accelerometer/gyro streaming from this manager | **Not present as separate methods** | Consume processed `CMDeviceMotion`. |
| Explicit public bud selection in this manager | **Not present** | Treat source changes as events, not an app-selected device. |

The declarations above were also checked with a compile-only Swift program targeting `arm64-apple-macosx14.0`; it referenced the manager, connection methods, delegate callbacks, authorization, sensor location, timestamp, quaternion, yaw, and rotation rate. Type checking succeeded. This verifies the API's compile-time availability, not Bluetooth transport, consent behavior, or live measurements.

Apple's general device-motion guide includes update-interval and magnetic-reference examples for **`CMMotionManager`**. Those examples must not be transplanted unchanged into a headphone service. The headphone header lacks these members. In particular, there is no supported basis here to claim that the application can request 100 Hz, select magnetic north for the earbuds, or remove yaw drift by toggling a headphone-manager setting.[3][6]

## Authorization and application identity

The application bundle must include `NSMotionUsageDescription`. Apple's headphone-manager documentation explicitly says the key is required on both iOS and macOS and that starting motion without it causes an application crash. A clear purpose string is: “Use AirPods head motion to blur the opposite side of your screen.”[2]

Check authorization before presenting sensor state. The authorization enum distinguishes no decision yet, a system restriction, user denial, and approval.[7] An authorized state does not imply the headphones are connected; an available service does not imply the user has granted access. Model these separately.

The manager exposes no standalone request-authorization function. Start the documented service in response to the application's explicit enable/setup action and let the operating system present its consent flow. Do not repeatedly start the service to pressure a denial into changing. Show the denied/restricted state and a route to system settings. The project should retain a stable bundle identifier and signing identity across iterative installations so permission behavior can be tested consistently; the precise interaction with ad hoc rebuilds must be observed on this Mac.

No microphone capture, heart-rate permission, location request, or custom Core Bluetooth scan is inherent in this motion design. Desktop screenshot/ScreenCaptureKit permission, if the rendering design needs it, is a separate grant with a separate purpose. Motion approval must not be presented as approval to capture the screen.

## Coordinate frames and neutral calibration

Apple documents yaw in radians and provides headphone-specific coordinate illustrations; phone-screen axes should not be assumed to be headphone axes. `CMAttitude` also supplies a quaternion and rotation matrix. The practical contract for the feature should be expressed in human terms: after calibration, a physical left turn raises right-side coverage, and a physical right turn raises left-side coverage.[2][8]

Apple's `multiply(byInverseOf:)` produces orientation change relative to a supplied attitude and mutates the receiver. Cache a **copy** of the neutral attitude, then copy each new attitude before applying this method; otherwise a mutable reference could corrupt calibration. This is preferable to treating the initial Euler yaw as a perpetual absolute compass heading.[9]

Recommended calibration behavior:

1. Require fresh, finite motion samples from a connected device.
2. Ask the wearer to face the display and choose **Center head**.
3. Reject calibration during fast motion, or collect a short stable window before accepting the center.
4. Store the neutral orientation and source/session metadata locally in memory.
5. Compute each subsequent orientation relative to that neutral reference.
6. Confirm left/right direction with a guided physical turn; expose an inversion control if necessary.
7. Require intentional recalibration after a discontinuity rather than guessing that a new orientation faces the screen.

For an initial upright seated prototype, wrapped yaw difference can be a diagnostic baseline: `atan2(sin(yaw - neutralYaw), cos(yaw - neutralYaw))`. It handles the ±π boundary, but it should not replace quaternion-relative testing when the head is also tilted. Quaternion multiplication order and extraction must be tested against Apple's helper and real left/right motion rather than chosen by memory. A model that works for a synthetic Euler rotation alone is not sufficient.

Do **not** continuously redefine center merely because the head is stationary. If the wearer looks left and stays there, that policy would eventually call the turned pose neutral and remove the right-side blur precisely when it is wanted. Stationary input is a candidate for noise estimation; it is not evidence of facing the display.

## Drift, timing, and smoothing

The examined headphone API offers no explicit drift estimator or reset command, and the cited Apple product and API pages publish no long-duration yaw-error bound. General reference-frame documentation describes magnetometer-corrected frames, but it does not create a reference-frame selector on this headphone manager. Therefore long-term drift and discontinuities remain real-device questions, not solved API features.[3][10]

Keep raw orientation, calibrated angle, confidence/freshness state, and visual interpolation distinct. Reject NaN/infinite values and out-of-order timestamps. Sample timestamps are seconds since device boot according to `CMLogItem`; also record local monotonic receipt time so delivery stalls can be detected without assuming a remote transport's clock mapping is perfect.[11]

Choose smoothing from measured behavior. An initial exponential filter with `alpha = 1 - exp(-dt/tau)` makes interpolation independent of update frequency. A prototype time constant around 80–150 ms, a dead zone around 5–10 degrees, and full coverage around 25–35 degrees are **tuning proposals**, not Apple specifications or proven safe limits. Actual values should reflect jitter and the desired privacy response time. Clamp elapsed time after a long gap instead of pretending one old sample describes continuous movement.

The renderer can animate at display cadence using the most recent validated target; it does not require the sensor to run at the same cadence. Keep processing lightweight on a serial queue, marshal UI updates onto the main actor, and avoid a queue of obsolete animation commands. Fast activation with a somewhat slower release can reduce flicker, but release must remain responsive and must never overshoot into negative or opposite-side coverage.

## Connection lifecycle and failures

Keep the manager and delegate alive for the lifetime of the enabled service. The local delegate header states that callbacks execute on the motion operation queue, or on the main thread when no operation queue was specified.[3] This makes explicit actor/queue boundaries important; a delegate callback must not directly mutate SwiftUI state from an arbitrary queue.

Use a state machine such as `disabled → awaitingPermission/awaitingDevice → calibrating → tracking`, with separate `stale`, `disconnected`, and `error` states. Register connection updates before waiting for headphones. Check availability again upon connection. Starting while unavailable must not leave the application permanently inert when a device later appears.

On disappearance or a watchdog timeout, invalidate “live tracking” immediately. A visual privacy feature should make loss visible and use a clearly documented response. A conservative default is an opaque shield while enabled tracking is unavailable, with an always-accessible pause/quit mechanism. Merely freezing a weak old blur or instantly revealing the desktop would not honestly preserve the feature's privacy intent. This is a product recommendation, not an Apple requirement.

Detect changes in `sensorLocation` and test their actual continuity. Do not automatically assume every source change resets orientation, but do not conceal a large jump either. If continuity cannot be established, request recentering while retaining the declared fallback. Reset session state on sleep/wake, service restart, or prolonged absence. Include a session-generation token so callbacks already queued from an old run cannot reactivate a stopped overlay.

Stop device-motion and connection-status updates when the feature is disabled or the process quits. The Mac menu-bar app may legitimately remain active while other applications are frontmost; applying mobile foreground-only rules blindly would defeat desktop protection. A future iOS app must separately account for platform background execution limits.

## Hardware acceptance matrix

| Test | Evidence required before claiming success |
|---|---|
| Specific AirPods Pro 3 support | Actual samples on this Mac with device/model, OS, and firmware recorded by the wearer or device UI. |
| Motion consent | Fresh install/request, allow, deny, restricted if available, and settings recovery observed. |
| Neutral pose | Stable angle near zero while facing the display, with measurable jitter. |
| Direction | Repeated physical left turns affect only the right side; right turns affect only the left. |
| Sustained turn | Right-side obscuration persists during a held left pose for multiple minutes, and vice versa. |
| Mixed pose | Turn while nodding/tilting; no reversal or sudden reveal. |
| Wrapping | Synthetic ±π crossing plus physical large-turn behavior; no numerical jump. |
| In-ear changes | Remove either bud, remove both, replace them; observe source, state, and fallback. |
| Automatic Ear Detection | Test the enabled state and document behavior if disabled. |
| Audio routing | Test silent operation, playback, microphone use, calls, and automatic switch to another Apple device. |
| Stalls and reconnect | Bluetooth disconnect/reconnect, sleep/wake, lock/unlock, and stale timestamps handled. |
| Calibration discipline | Attempt center while moving, while unavailable, and after a disconnect. |
| Performance | Observed sample frequency, jitter, stall count, end-to-end response, and power behavior. |
| Screen privacy | Actual text obscuration measured at multiple content sizes/contrast levels and viewing positions. |

The capability statement should remain “designed for supported AirPods head tracking” until the specific hardware checks pass. A slider demo, successful compilation, or a connected Bluetooth status does not satisfy a live head-tracking claim.

## Sources

All online sources were consulted on September 13, 2026. API pages have no stable publication date unless indicated. Local headers are primary Apple SDK evidence rather than third-party documentation.

1. Apple. [What’s new in Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179/). WWDC23, 2023. Native macOS introduction, one-bud streaming, source location, connection behavior.
2. Apple. [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager). Current API documentation and [machine-readable documentation](https://developer.apple.com/tutorials/data/documentation/coremotion/cmheadphonemotionmanager.json). Platform availability, required usage description, interface, coordinate illustration.
3. Apple. Installed macOS 27.0 SDK, `CoreMotion.framework/Headers/CMHeadphoneMotionManager.h`, `CMHeadphoneMotionManagerDelegate.h`, `CMDeviceMotion.h`, and `CMAttitude.h`. Local access: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreMotion.framework/Headers/`. Exact availability and exposed member list, plus compile-only arm64 macOS 14 type check.
4. Apple Support. [AirPods Pro 3 — Tech Specs](https://support.apple.com/en-au/125135). Product introduced 2025. Hardware/features; no unpublished inertial component details inferred.
5. Apple. [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion). Processed signal meaning and sensor fusion overview.
6. Apple. [Getting processed device-motion data](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data). Distinction between generic `CMMotionManager` examples and headphone APIs, timestamp use, hardware-dependent frequency.
7. Apple. [authorizationStatus()](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/authorizationstatus()). Also installed `CMAuthorization.h` for the four enumerated states.
8. Apple. [CMAttitude.yaw](https://developer.apple.com/documentation/coremotion/cmattitude/yaw). Units and rotation meaning.
9. Apple. [multiply(byInverseOf:)](https://developer.apple.com/documentation/coremotion/cmattitude/multiply(byinverseof:)). Relative attitude, mutable receiver, reference caching.
10. Apple. [CMAttitudeReferenceFrame](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe). General reference-frame definitions; no inference of an absent headphone selector.
11. Apple. [CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp). Seconds since device boot.
