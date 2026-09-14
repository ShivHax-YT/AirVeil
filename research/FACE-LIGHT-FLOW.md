# Face light and camera recovery update

AirVeil 0.13.0 adds automatic low-light activation with a manual Off control. This is a screen border rendered by AirVeil, not an API toggle for Apple's Edge Light. It begins off each check, uses only the built-in display, and changes neither display backlight brightness nor a persistent preference.

## Why the system effect remains separate

Apple exposes Edge Light supported/enabled/active properties as read-only in the installed macOS 26.5 SDK. Apple documents turning the effect and its automatic low-light option on/off in the Video menu. There is no public setter in the inspected headers. The existing public action opening Video Effects is retained as a separate system-controls capability; it cannot honestly implement a direct application On/Off switch. A previously enabled Apple system effect must be disabled through those system controls if the wearer wants it off. AirVeil does not silently alter that preference.

Sources inspected September 13, 2026:

- [Apple Support: Use Edge Light to illuminate your face during video calls](https://support.apple.com/en-us/125934)
- [Apple Developer: isEdgeLightEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isedgelightenabled)
- Installed SDK `AVFoundation.framework/Headers/AVCaptureDevice.h`, lines 3966–3987: enabled, active, and supported are readonly.
- [Prior local research and primary source links](EDGE-LIGHT-CENTER-CHECK.md)

## Evidence-driven flow

1. Begin the existing bounded camera check with AirVeil's face light off.
2. Analyze the face's inner bounding rectangle, translating Vision's lower-left normalized coordinates to the luma buffer's top-left rows. Surrounding windows or dark backgrounds no longer dominate the illumination measurement.
3. Automatically illuminate the rounded rectangular border only after two distinct consecutive frames show one plausible, nearby face but cannot produce a reliable frontal pose, with face-local luminance below 0.18. This threshold is a heuristic; no photometric or physical angle accuracy guarantee is claimed.
4. Missing faces, multiple faces, tiny distant faces, stale/untimed frames, and clearly measurable off-axis turns do not activate the light. A confident usable frontal face never needs the card merely because its pixels are dark.
5. Automatic activation continues the same capture. Only one automatic activation is attempted per check; manual Off prevents relighting for that check. It clears pre-light hold evidence; it does not restart the camera, extend its existing deadline, save a new center, or grant alignment.
6. The face light shuts off when the capture stops, succeeds, fails, loses the face for two observations, has no fresh frame for 0.8 seconds, or the session becomes inactive. An explicit Off action remains available while it is on.
7. Success uses the unchanged five-degree camera gate and paired stationary AirPods evidence. A 1.45-second success presentation gives the reference-inspired loops and smile time to finish; capture stops at evidence acceptance rather than waiting for the animation.

## Resume and delivery continuity

The old coordinator could lose an alignment within the same AirPods epoch and then refuse recovery because it had already attempted that epoch. It now grants one recovery when a previously live alignment is lost. A failed recovery is not another loss and cannot create repeated checks. Explicit Enable resumes the saved direction, preserves a valid current alignment, and does not redefine the center.

An acquisition-validated sample now carries an explicit continuity flag. A long gap between UI deliveries can preserve a verified offset only when the acquisition owner has examined every underlying sensor sample and changed epochs for true gaps, source changes, clock changes, or origin changes. Unverified samples retain the original conservative behavior. Coalesced delivery always clears stationary evidence, so a busy UI cannot fabricate a camera/IMU hold.

## Verification

The following standalone Swift 6 suites passed with injected camera/light/motion and isolated preferences; no camera permission, capture, display illumination, or device testing was performed by these suites:

- Camera coordinator: 115 checks, including empty-room darkness, off-axis darkness, distinct-frame automatic activation, manual override, one capture/unchanged center, light cleanup, same-epoch recovery and bounded retry.
- Camera service: 63 checks, including default-off/stop/interruption light lifecycle, truthful unsupported light state, face-region brightness under a bright background, and coordinate conversion.
- Notch guidance: 48 checks, including measured low-light conditions versus missing/distant/off-axis faces.
- Heading fusion: 60 checks, including retained nonzero heading under verified coalescing, cleared stationary evidence, strict epoch/clock invalidation, and unchanged centered calibration gates.

Wearer validation of illumination strength, exposure behavior, head direction across varied lighting, AirPods removal, and native animation is deferred until the full update is installed, as requested.
