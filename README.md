# AirVeil

AirVeil is a native macOS menu-bar app that uses AirPods head motion to progressively obscure the opposite side of your desktop. Turn left to blur the right side; turn right to blur the left. The untouched side stays transparent. Clicks and scrolling are blocked in blurred areas by default, with a control to block the entire affected display instead.

## Requirements

- macOS 14 or later and a Metal-capable Mac.
- AirPods with dynamic head tracking; AirPods Pro 3 are the initial hardware test target.
- Motion access for the sensor and Screen Recording access for the live desktop effect.
- Optional camera assistance needs the Mac’s built-in camera and a separate Camera permission. It starts off by default.
- Xcode Command Line Tools to build. Full Xcode's offline Metal compiler is not required.

## Build and run

```sh
# Once per Mac, before the first build:
python3 scripts/setup-signing.py
./scripts/install.sh
```

This builds an app for the current Mac's architecture, signs it with a persistent local development identity, installs it at `/Applications/AirVeil.app`, and starts it quietly in the menu bar. An existing AirVeil install is retained in the ignored build directory. The build script prefers the installed macOS 26.5 SDK to avoid a missing SwiftUI macro plugin in this Mac's default SDK; set `AIRVEIL_SDK` to use another complete SDK.

To build without installing, run `./scripts/build.sh`. Open `/Applications/AirVeil.app` to return to settings later.

## Notch recenter coach

Hover near the notch to reveal **Set center**, **Enable/Pause**, and settings. **Show Notch Controls** in the AirVeil menu is an alternative to hovering. With camera assistance enabled, automatic wake/rewear checks and manual Set center show a circular mirrored preview beneath the hardware cutout. Directional guidance and a fine alignment rail turn red when a correction is needed and green while the accepted pose is held. Measured dim frames with failed face detection produce a specific lighting message. No-face, multiple-face, motion, and camera errors have separate guidance.

The coach shows confirmation only when the existing camera/AirPods coordinator has restored a valid heading. It then dismisses after a short settle. Progress reflects accepted paired samples; it is not an arbitrary animation timer. A first setup can include the existing prompted head turn. Recovery still measures the current angle against the saved reference, without replacing zero. Camera images are released on stop, cancel, timeout, and sleep.

The native panel opens downward, keeps important content outside the dead camera cutout, and does not become the key window. It selects the notched display even when an external monitor is the main display, with a floating top-center fallback on unnotched screens. Reduce Motion removes springs and scale motion. Settings remain available for advanced controls, and normal startup keeps them hidden. Use `open /Applications/AirVeil.app --args --settings` for explicit settings at launch.

**Preview Notch Animation** in the AirVeil menu shows a labeled demonstration without starting a camera check or changing calibration. Cancel closes it. This preview is a visual demonstration, not sensor validation.

Run `bash scripts/test-notch-ui.sh` for geometry and native controller lifecycle checks plus nine 2x rendered states in `build/notch-previews/`. The regular test script covers the camera/coach evidence, low light, crop mapping, preview lifetime and cancellation. [Notch engineering research](research/NOTCH-RESEARCH.md) and the [reference motion study](research/NOTCH-MOTION-STUDY.md) document the implementation decisions.

## Setup

1. Connect and wear the AirPods on this Mac.
2. AirVeil detects connected, worn AirPods automatically. Allow Motion access when requested.
3. Face the center of the display and choose **Set center**. In manual mode, repeat this after removal, a motion gap, or a lost sensor reference. The optional camera setup below is intended to restore the original direction without repeating this step; its physical accuracy is still being tested.
4. Confirm in the preview that a physical left turn obscures the right side. Use **Invert direction** if needed.
5. Choose **Allow screen capture** and enable AirVeil in the macOS privacy settings. Reopen the app if macOS requests it. Subsequent builds use the same signing identity to preserve this approval.
6. Choose **Enable desktop effect**.

### Optional camera assistance

Camera assistance is **off by default**. Enable it explicitly in settings to request Camera access. The app uses only the built-in Mac camera, processes images locally in memory, and does not select an iPhone or external camera automatically.

For first-time setup, face your reference display and choose **Set center**. Hold briefly while its direction is measured, then make the prompted short left or right head turn and hold again. This measures the camera’s sign convention. The app saves the screen-facing camera angle and that sign, separately from the temporary AirPods alignment.

After rewear, a brief camera check measures your **current angle**, including a visible off-axis turn; it does not call that angle zero. Keep your head briefly steady while one face is visible. Recovery attempts stop on success or after at most 12 seconds; initial setup has a 20-second limit. If a check cannot finish, the effect stays paused and **Refresh direction** can start another attempt. Pause cancels pending camera recovery; sleep/inactivity stops camera work. Camera activity may show the Mac’s normal camera indicator.

This is an experimental alternative, not a confirmed fix: camera angle accuracy and the assumed timing margin still require an opted-in physical test. A moved camera/display, changed framing, large turn or tilt, poor view, or multiple faces can prevent recovery. Re-establish the screen center if the physical setup changes. The previous AirPods-only retained-reference experiment failed the wearer’s removal/rewear test; keeping the same copied sensor value did not preserve the correct physical zero.

**Pause & Clear Screen** in the menu bar immediately removes all overlays. The app also registers **Control–Option–Command–P** as a global pause shortcut and reports when registration fails. Quitting removes the effect.

The preview slider uses a synthetic sample desktop and requires no screen capture. Its simulation is separate from live sensor verification.

## Stable permissions across updates

Builds reuse one certificate and private key in a dedicated keychain under `~/Library/Application Support/AirVeil/Signing`, outside this repository. The keychain password is a random value stored in that private directory for local build automation. Do not share this directory or delete it between builds. The build fails if its identity is missing; it never silently falls back to ad hoc signing. The signing helper temporarily includes this keychain in the user search list, restores the original list, and locks it afterward. It does not add a trusted root or change system trust settings.

Migrating from an older ad hoc build requires one new macOS screen-capture approval for the persistent identity. The app checks actual ScreenCaptureKit access; the preflight indicator alone no longer prevents capture. macOS still controls consent and may require it again after revocation, an identity replacement, or OS policy changes. This local certificate is for development on this Mac, not a notarized public release.

## Controls and behavior

- **Directional half / Whole-screen sweep** selects opposite-half blur or a moving blur edge across the full display. Turning left starts at the right edge and sweeps left; turning right mirrors it. At the full-effect angle, the entire display is blurred.
- **Displays** shows connected displays and lets you choose which ones receive blur. Selection is saved by stable display identity. **Check displays** refreshes the list. Changing selection pauses the effect.
- **Block clicks and scrolling while blurred** intercepts pointer input in the blurred area or the entire affected display. AirVeil settings, the menu bar, and the global pause key remain available. Keyboard focus is unchanged.
- **Turn off displays when AirPods are removed** is an optional, separate control that works even while blur is paused. After live headphone motion has been received, a headphone disconnect turns off all displays after a 1.5-second reconnect delay. Keep Automatic Ear Detection enabled; removing one bud may hand tracking to the other, so test by removing both. Bluetooth disconnection also triggers it. Motion gaps and calibration jumps alone do not.
- Automatic display off uses macOS display sleep, without changing brightness or power preferences. Whether a password is required on wake follows **System Settings → Lock Screen → Require password after screen saver begins or display is turned off**. Choose **Immediately** for password protection. AirVeil never unlocks the Mac on reconnection. The app's **Lock Screen settings** button opens that page.
- **Reset defaults** restores effect settings, selects all connected displays, disables camera assistance and automatic display off, and pauses the effect. It does not revoke macOS permissions or replace saved calibration values.
- Default onset: 8 degrees; full effect: 32 degrees.
- Adjustable blur, edge feather, and response time.
- **Opaque cover** removes source color at full strength for stronger obscuration.
- AirPods motion starts automatically at launch and resumes the existing stream on reconnection. Initial startup stalls and actual stream errors retry with a bounded delay. Once a center exists, silence alone does not restart its stream: if motion stays unavailable, the app asks you to reconnect AirPods or restart AirVeil, with Set center required after a restart in manual mode, or a fresh alignment in camera mode.
- In **manual mode**, removal, stale input, a detected reference jump, source/clock change, or stream restart invalidates the usable center. Its copied value is retained for diagnostics, but cannot drive blur until an explicit **Set center**. App relaunch also requires a manual center. Stillness never silently chooses a new zero.
- With **camera assistance**, the saved screen direction survives sensor resets as camera calibration data. Each new sensor epoch needs a fresh camera alignment before its heading can drive blur. The current implementation uses one reference direction for the selected displays; it does not infer each monitor’s physical angle.
- Lost or invalid tracking automatically pauses the effect and clears blur and input blockers. A previously active effect can resume after a valid manual center or camera alignment and an active Mac session. Explicit Pause, display selection change, or reset cancels that resume intent. Capture failures also pause and clear. The normal desktop is visible while paused.
- Starting a drag before blur appears may leave that already-started drag with the underlying app; the blockers intercept newly delivered pointer events in covered regions.
- Sleep or session resignation pauses the effect, discards desktop frames, and stops camera checks. The motion service can remain available, but an unobserved gap invalidates its manual reference. Camera mode requires a new alignment on return. A manually paused effect stays paused after wake.
- Display off is requested once per removal. Reconnecting during the delay, pressing Pause, switching this setting off, or quitting cancels a pending request. Waking while the AirPods remain absent does not immediately turn the displays off again. Reset defaults disables this option.
- Display reconfiguration requires rebuilding capture with a deliberate pause/re-enable.

## Privacy and platform limits

Motion, desktop frames, and optional camera images are processed locally, in memory. Camera setup persists only small numeric calibration/configuration records; it does not save face images or biometric templates. Temporary motion/pose buffers are bounded and remain in RAM. Headphone acquisition runs separately from UI work, and the app coalesces outdated visual poses while retaining real sensor continuity failures. The app captures no audio, runs no server, and includes no analytics or cloud inference. Its own windows are excluded from its capture streams to prevent repeated blur feedback. It does not save recordings.

Software blur changes the same pixels for everyone looking at the display. It is not an optical privacy filter, cannot detect bystanders, and does not guarantee unreadability of all content. Transition edges are partly visible. Secure macOS surfaces and every fullscreen application are not guaranteed to be covered.

The wearer physically confirmed that the retained AirPods reference produced the wrong zero after removal and reinsertion while looking left or right. Manual mode therefore refuses that unverified reference. Camera assistance adds a fixed visual reference, not absolute compass heading or eye gaze. It estimates mostly horizontal head turns with conservative face and tilt limits. Camera capture timestamps are converted to the Mac host clock, but the AirPods source clock relationship is not established; the prototype uses a steady overlap window with an assumed 200 ms timing guard. This assumption and camera pose accuracy remain physical validation requirements. A camera identifier also cannot detect every physical camera or seating change.

iPhone and iPad support headphone motion, but a normal app cannot reproduce this arbitrary system-wide overlay across other apps. A future mobile implementation would need an explicitly limited app-owned content surface. The implemented target is macOS.

## Energy work

Current source changes isolate motion telemetry and animated strengths from the full settings view, publish small tracking snapshots only when displayed values change, suspend hidden previews, and draw on demand. The animation clock rests after the effect settles. Transparent output and genuinely solid opaque output bypass unnecessary source copying and Gaussian blur work; intermediate blur still processes the source it needs.

Native desktop capture/output resolution and the requested maximum 60 fps capture cadence are unchanged. Lower-resolution blur levels and lower content refresh rates remain research options. These changes target unnecessary work; no measured energy or battery-life saving is claimed yet. Before/after runtime measurement and visual validation are still required.

## Research and validation

Four research reports precede implementation:

- [Sensor API](research/01-sensor-api.md)
- [Sensor feasibility and calibration](research/02-sensor-feasibility.md)
- [Desktop capture and overlays](research/03-desktop-overlay.md)
- [Blur and animation](research/04-blur-animation.md)

Follow-up research addresses the failed reference-retention test and energy use:

- [Camera API feasibility](research/CAMERA-ANCHOR-RESEARCH.md)
- [Heading fusion and timing design](research/HEADING-FUSION-DESIGN.md)
- [Energy analysis and priorities](research/ENERGY-RESEARCH.md)

[Architecture decisions](research/DECISIONS.md) and [acceptance plan](research/VALIDATION-PLAN.md) distinguish documentation, synthetic tests, and physical evidence.

Run `./scripts/test.sh --performance` to include the synthetic native-resolution GPU benchmark. Run `./scripts/test.sh` for deterministic motion/fusion math, camera-service and coordinator boundary tests, motion-delivery and app-lifecycle regressions, and actual Metal GPU render tests. Synthetic PNGs are written under `.build/render-artifacts/`. Passing these checks does not establish physical AirPods direction, sustained drift behavior, or privacy effectiveness. See [validation status](validation/STATUS.md) for current evidence.

## Implementation

Swift / SwiftUI / AppKit, Core Motion, AVFoundation, Vision, ScreenCaptureKit, Metal, and Metal Performance Shaders. Original code informed by public Apple documentation and the visual behavior of [macTilt](https://github.com/lqSky7/iphone-duo-macos-animation); no macTilt source is copied.
