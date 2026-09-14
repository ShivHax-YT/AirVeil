# Presence-aware AirPods removal

Anonymous seated-presence detection and idle-display-sleep prevention have public macOS APIs. Real built-in-display brightness control on this Apple silicon Mac requires a different boundary: the legacy public IOKit path is unavailable in practice here, while the private DisplayServices brightness reader works. A production dim-and-restore feature can isolate that private interface and handle failure explicitly, but should not describe it as an Apple-supported public API.

This report covers the candidate interfaces and their limitations. Inspection was read-only: no camera capture, brightness write, power assertion, system UI, lock, or settings change occurred.

## Built-in hardware brightness

The inspected machine runs macOS **26.6.2 (25G83)** on an **Apple M5 MacBook Air, Mac17,3**. Public IOKit headers declare `IODisplayGetFloatParameter`, `IODisplaySetFloatParameter`, and `kIODisplayBrightnessKey`.[^1] However, a read-only `IOServiceGetMatchingServices` enumeration for `IODisplayConnect` succeeded with **zero services**. The current SDK also marks `CGDisplayIOServicePort` unavailable to Swift, with the diagnostic “No longer supported.” This prevents treating an old Intel-era snippet as a viable current built-in-display adapter.[^2]

The private framework at `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices` loaded successfully through `dlopen`. Both brightness getter and setter symbols were present. Calling **only the getter**, against an online display selected with `CGDisplayIsBuiltin`, returned success and brightness **0.81249994**. Setter existence is not evidence that a write, restore, or future OS version will work. The observation is a point-in-time brightness reading, not a value the application should hard-code.

Two independent open-source implementations document and use this interface. `nriley/brightness` prioritizes DisplayServices, then CoreDisplay, then legacy IOKit; its source explicitly notes the Apple silicon limitations of the older route.[^3] Hammerspoon's current screen implementation similarly calls DisplayServices first and labels its declarations private APIs.[^4] These sources establish an observed integration pattern, not Apple's compatibility guarantee.

| Candidate | Status | Recommended boundary |
|---|---|---|
| `IODisplayGet/SetFloatParameter` with the brightness key | Public SDK interface; no matching display service found here | Treat absence as unsupported; do not invent a service or report success. |
| `DisplayServicesGetBrightness(CGDirectDisplayID, float *) -> int` | Private; actual getter succeeded on this Mac | Runtime lookup, checked error and finite normalized result. |
| `DisplayServicesSetBrightness(CGDirectDisplayID, float) -> int` | Private; symbol present, write not exercised | Explicit isolated adapter, checked return and later readback verification. |
| `CoreDisplay_Display_*UserBrightness` | Private alternative used by existing projects | No additional fallback is necessary merely because the symbols exist. |
| A translucent overlay or gamma change | Changes rendered appearance, not the requested built-in backlight setting | Do not substitute for hardware brightness. |

The verified Swift getter ABI is `@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32`. The setter declaration in the inspected source is `int DisplayServicesSetBrightness(CGDirectDisplayID, float)`. Load both together and fail cleanly if either cannot be resolved. Do not call an arbitrary address or assume a symbol's presence guarantees the target display supports it.

### Dimming and restoration contract

Capture the original normalized value once, immediately before a dim episode, and bind it to the selected built-in display. Enumerate actual online displays and use `CGDisplayIsBuiltin`; the main display may be external.[^5] Reject missing, nonfinite, or out-of-range brightness readings, because a dim operation without a trustworthy original value cannot promise restoration.

For a requested 5–10% level, choose a configured normalized target in `0.05...0.10`, and apply `min(original, target)` so the feature never brightens an already darker panel. This is a percentage of the API's brightness range, not a claim about linear light output or nits. Repeated presence samples must not overwrite the original value with the already-dimmed value.

Treat brightness as temporarily owned by the feature. Restore on the intended exit paths, including AirPods return, feature disablement, camera failure, and orderly shutdown, while checking that the same built-in display is still available. If the current value has changed away from the feature's last applied level, preserve a possible user adjustment instead of repeatedly fighting it. Automatic-brightness interaction and exact restore tolerance require a real-device test; no global auto-brightness setting should be changed to make this feature work.

A successful setter return should be followed by a checked read when assessing whether dimming actually occurred. Failure must leave a clear unsupported/error state rather than a false “dimmed” status. A hard process kill can prevent in-process cleanup; any claim of guaranteed restoration through crashes would require a separately designed recovery mechanism. This report does not establish such a mechanism.

## Presence without facial identity

Use `VNDetectHumanRectanglesRequest` with revision 2 and `upperBodyOnly = true` as the primary detector. It returns human bounding boxes and confidence without requiring a visible frontal face. The request exists from macOS 10.15; revision 2 and the explicit upper-body property are available from macOS 12. The default is upper-body detection.[^6][^7] This is a better match for a seated laptop-camera view than a full-body requirement.

Use the previously accepted seated geometry as a location anchor, not as a biometric template. A candidate can be associated using overlap with the seat region, normalized center displacement, width/height or area ratios, and continuity with the previous accepted observation. These comparisons should occur in unmirrored normalized image coordinates. No image, face embedding, name, or body identity needs to be persisted.

`VNTrackObjectRequest` can maintain a selected region through subsequent frames via `VNSequenceRequestHandler`. Its documented `inputObservation` contract distinguishes a detector observation, which starts a tracker, from a prior tracker result, which continues it.[^8] Tracking must be periodically checked against fresh human detections; a box tracker alone can follow a chair, background, or wrong person after occlusion. The local SDK also notes that the fast/accurate tracking-level setting has no effect on object-tracker revision 2.[^9]

Optional `VNDetectHumanBodyPoseRequest` shoulder and neck evidence can reinforce the foreground torso association. Apple recommends substantial visible body regions, a subject occupying roughly one-third of image height, and cautions that crowds and loose clothing reduce accuracy. Recognized points with confidence zero are invalid.[^10] Do not require hips or a complete skeleton in a cropped seated-camera view; otherwise a useful corroborating signal becomes another source of false absence. The 3D pose request is not a shortcut to reliable identity or seat ownership: it only returns the most prominent person, which can change.[^11]

### Foreground and bystander limits

An initial centered foreground torso that matches the established seat region is stronger evidence than any human rectangle anywhere in the image. A small background person, a new person at the side, or a large discontinuous box jump should not silently replace the seated track. If several candidates plausibly overlap the same track, report ambiguity rather than choosing whichever is largest.

Turning the head away must not immediately become absence: torso detection and short-term tracking can continue even when face detection fails. Nevertheless, Apple's documentation does not guarantee recognition for every back view, posture, occlusion, lighting condition, or crowded scene. The resulting feature detects anonymous occupancy near the established seat; it cannot prove that the same person remains there if another person takes that seat.

Maintain distinct states for **present**, **absent**, and **unknown/ambiguous**. Require multiple fresh observations and a measured interval before claiming departure. A failed Vision request, stale frame, camera interruption, low confidence, or unavailable camera is not positive evidence that the seat is empty. The policy for prolonged unknown state must be explicit and must not accidentally invoke the old immediate-removal sleep path.

Camera permission remains necessary, even though identity is not used. The permission and visible camera indicator do not imply capture must continue indefinitely: acquisition should run only in the feature's intended AirPods-removed/presence-check lifecycle, and end on teardown, inactive session, or relevant sleep events. No microphone, screen recording, network transfer, or face-recognition service is needed.

## Idle display sleep and manual actions

While the AirPods are removed and seated presence is established, the public assertion type `kIOPMAssertionTypePreventUserIdleDisplaySleep` can prevent automatic display dimming/off caused by inactivity. Apple states that it does not light an already-off display, does not prevent every other sleep cause, and also prevents idle system sleep while active.[^12] It is appropriate for keeping a deliberately dimmed display awake, without simulating user input.

Create it with `IOPMAssertionCreateWithName`, `kIOPMAssertionLevelOn`, a descriptive reason, and a stored assertion ID. No special privileges are required for this API.[^13] Release the stored ID exactly once on teardown and failed setup; `IOPMAssertionRelease` deactivates the assertion when its retain count reaches zero.[^14] The assertion lifetime should follow the same owned dim episode rather than be recreated on every camera frame.

Do **not** call `IOPMAssertionDeclareUserActivity` as a keepalive. Apple documents that it powers on the display, which would conflict with respecting a user-requested sleep.[^15] Likewise, do not synthesize keyboard/mouse events, change the password-delay setting, or run an unlock action.

An idle-sleep assertion is not an interlock for AirVeil's own explicit `pmset displaysleepnow` subprocess. Presence must be checked before that command is launched; cancel any pending application action when a present result supersedes it. A subprocess that has already requested display sleep cannot reliably be undone by cancelling the waiting task. On confirmed departure, release the presence assertion before invoking the existing authorized display-sleep path. The Mac's existing password policy still determines authentication after display sleep.

Public workspace notifications cover display sleep/wake and user-session switching. In particular, `sessionDidResignActiveNotification` is documented for switching a user session out; it is not documented as a universal “screen was manually locked” signal.[^16] Do not claim that existing session notifications alone detect every manual lock. The idle assertion does not unlock the Mac or bypass authentication, but strict camera-stop-on-lock behavior needs a separately verified lifecycle signal. Preserve manual Lock, lid-close, and Apple-menu sleep behavior, and do not automatically wake or unlock in response to camera presence.

### Practical manual-lock observation

Hammerspoon's mature caffeinate watcher registers `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` on `NSDistributedNotificationCenter`, separately from workspace display-sleep and fast-user-switching notifications. It removes both registrations when the watcher stops.[^17] Nudge independently uses the same distributed names to maintain its screen-lock state.[^18] This is a practical compatibility interface for pausing camera presence and releasing assertions on manual lock, but the names themselves are undocumented system notifications.

Foundation's distributed-notification mechanism is public, but Apple states that delivery latency is unbounded, notifications can be dropped, and the mechanism is not secure.[^19] Treat a lock event as a reason to stop optional activity; do not treat an unlock event as authentication or as sufficient evidence to wake a display. Retain the existing inactive-session and display-sleep guards. Startup already locked and a missed lock transition remain lifecycle cases requiring a separate state source or explicit handling; listening for future notifications does not reconstruct the initial state.

### Brightness restoration at sleep boundaries

No consulted Apple contract or mature open-source source established that `DisplayServicesSetBrightness` cannot wake a sleeping built-in panel. The function is private, so omitting `IOPMAssertionDeclareUserActivity` alone is insufficient evidence for such a guarantee. This is an unresolved behavior, not proof that the setter does wake it.

Use the public `CGDisplayIsAsleep` query with the selected built-in display, alongside the application's session/sleep flags. Apple defines a sleeping display as nondrawable and in reduced power mode.[^20] On a lock event while the display remains awake, restoring owned brightness is a reasonable intended action. If the display is already asleep, or the app is handling a transition into sleep, release the idle assertion immediately and defer the brightness write. Preserve the original value as a pending restoration obligation instead of discarding it.

After a system- or user-initiated wake and an allowed session state, restore only if the display is still the same target and its brightness is still owned by the dim episode. Do not trigger wake to perform restoration, and do not interpret display wake as screen unlock. A read-before-write awake check narrows the race but cannot provide a formal atomic no-wake guarantee for an undocumented setter; later device validation remains necessary.

## Candidate implementation and verification boundary

The components should remain independently injectable: an anonymous presence evidence engine, a bounded camera transport, a built-in-brightness adapter, an idle-display assertion owner, and the existing explicit display-sleep service. This makes it possible to exercise stale frames, bystanders, loss of the selected body, missing private symbols, invalid brightness reads, setter failures, duplicate teardown, and restored ownership without camera or backlight access.

Read-only evidence supports using public Vision and IOPM interfaces, and supports a runtime-checked private DisplayServices adapter on this machine. It does not yet prove dim-and-restore behavior, manual brightness interaction, turning-away reliability, bystander rejection, low-light performance, or lock lifecycle behavior. Those are concrete later wearer/device validation items, not properties that should be inferred from successful compilation.

## Sources

[^1]: Apple, [IODisplaySetFloatParameter](https://developer.apple.com/documentation/iokit/1574926-iodisplaysetfloatparameter), and installed SDK `IOKit.framework/Headers/graphics/IOGraphicsLib.h` lines 100–143 and `IOGraphicsTypes.h` brightness key. Accessed September 13, 2026.
[^2]: Installed Apple SDK `CoreGraphics.framework/Headers/CGDisplayConfiguration.h` lines 370–373; read-only Swift compile diagnostic and IODisplayConnect enumeration on September 13, 2026. Public SDK root: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks`.
[^3]: Nicholas Riley, [brightness.c](https://github.com/nriley/brightness/blob/f6174c5764bd2292424343f49c99a10e0d31b517/brightness.c), pinned commit `f6174c5764bd2292424343f49c99a10e0d31b517`, February 28, 2021; declarations and implementation lines 122–195. Accessed September 13, 2026. Historical source pattern, cross-checked against current local read-only runtime evidence.
[^4]: Hammerspoon, [extensions/screen/libscreen.m](https://github.com/Hammerspoon/hammerspoon/blob/ea249affa803be54e70b16896ccb79077aca3605/extensions/screen/libscreen.m), pinned file-change commit `ea249affa803be54e70b16896ccb79077aca3605`, November 18, 2025; private API declarations and lines 638–709. Accessed September 13, 2026.
[^5]: Apple, installed CoreGraphics SDK declarations for `CGGetOnlineDisplayList` and `CGDisplayIsBuiltin`; read-only display enumeration and private getter probe September 13, 2026. Only the selected built-in display's normalized brightness was read; no setter was called.
[^6]: Apple, [VNDetectHumanRectanglesRequest](https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest), accessed September 13, 2026.
[^7]: Apple, [upperBodyOnly](https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest/upperbodyonly), and installed `Vision.framework/Headers/VNDetectHumanRectanglesRequest.h` lines 18–50, accessed September 13, 2026.
[^8]: Apple, installed `Vision.framework/Headers/VNTrackObjectRequest.h` and `VNTrackingRequest.h`, tracker construction and input-observation contract; accessed September 13, 2026.
[^9]: Apple, installed `Vision.framework/Headers/VNTrackingRequest.h` tracking-level documentation; accessed September 13, 2026.
[^10]: Apple, [Detecting Human Body Poses in Images](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images), accessed September 13, 2026.
[^11]: Apple, [Identifying 3D human body poses in images](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images), accessed September 13, 2026.
[^12]: Apple, [kIOPMAssertionTypePreventUserIdleDisplaySleep](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep), and installed `IOKit.framework/Headers/pwr_mgt/IOPMLib.h` lines 295–314, accessed September 13, 2026.
[^13]: Apple, installed `IOKit.framework/Headers/pwr_mgt/IOPMLib.h` lines 757–781, `IOPMAssertionCreateWithName`; accessed September 13, 2026.
[^14]: Apple, [IOPMAssertionRelease](https://developer.apple.com/documentation/iokit/1557090-iopmassertionrelease), accessed September 13, 2026.
[^15]: Apple, [IOPMAssertionDeclareUserActivity](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity), accessed September 13, 2026.
[^16]: Apple, [NSWorkspace.sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification), accessed September 13, 2026. Existing AirVeil application sleep-command and lifecycle behavior inspected in `Sources/DisplaySleepService.swift` and `Sources/AppModel.swift`; no mutation was performed for this research.
[^17]: Hammerspoon, [libcaffeinate_watcher.m](https://github.com/Hammerspoon/hammerspoon/blob/0c7107fb8e206ca54cbc400c50a3005c3ce8748e/extensions/caffeinate/libcaffeinate_watcher.m), pinned file-change commit `0c7107fb8e206ca54cbc400c50a3005c3ce8748e`, July 29, 2025; lines 199–255 and 259–274. Accessed September 13, 2026.
[^18]: MacAdmins Nudge, [Nudge/UI/Main.swift](https://github.com/macadmins/nudge/blob/63776aaa4134bfd15205cd05dc1c24d2b355bc79/Nudge/UI/Main.swift), pinned file-change commit `63776aaa4134bfd15205cd05dc1c24d2b355bc79`, May 7, 2026; lines 927–941. Accessed September 13, 2026.
[^19]: Apple, [DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter), accessed September 13, 2026.
[^20]: Apple, [CGDisplayIsAsleep(_:)](https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep(_:)), accessed September 13, 2026.
