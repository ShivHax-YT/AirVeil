# AirVeil

AirVeil is a native macOS menu-bar app that uses AirPods head motion to progressively obscure the opposite side of your desktop. Turn left to blur the right side; turn right to blur the left. The untouched side stays transparent. Clicks and scrolling are blocked in blurred areas by default, with a control to block the entire affected display instead.

## Download

Download [AirVeil 0.13.0 beta 1](https://github.com/ShivHax-YT/AirVeil/releases/tag/v0.13.0-beta.1) and its matching `.dmg` from GitHub Releases. Open it and drag AirVeil into Applications, then launch AirVeil from Applications. The current download is an Apple silicon prerelease for macOS 14 or later; hardware acceptance is still pending. It is development-signed, not Apple-notarized, so macOS may block its first launch on another Mac. Repository access is required while this repository is private.

Build the distributable locally with `bash scripts/package-dmg.sh`; it produces a DMG and SHA-256 checksum under `build/releases/`. The package includes only the app, an Applications shortcut and installation notes; local preferences, diagnostics, recordings and signing secrets are excluded.

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

This builds an app for the current Mac's architecture, signs it with a persistent local development identity, installs it at `/Applications/AirVeil.app`, and opens the Settings walkthrough on its first launch. Later launches stay in the menu bar. An existing AirVeil install is retained in the ignored build directory. The build script prefers the installed macOS 26.5 SDK to avoid a missing SwiftUI macro plugin in this Mac's default SDK; set `AIRVEIL_SDK` to use another complete SDK.

To build without installing, run `./scripts/build.sh`. Open `/Applications/AirVeil.app` to return to settings later.

## First-launch walkthrough

The first time you open an installed or locally built AirVeil app, Settings opens with an animated welcome and a 14-step spotlight tour. The rest of Settings dims while the actual control is highlighted and scrolled into view. Back, Continue, Skip tour, and Get started support a self-paced walkthrough. Closing the window also dismisses the tour. **Take a tour** at the top of Settings replays it later; completion is saved per macOS user and survives app updates. Downloading or copying the app does not execute it.

The tour covers the preview, head tracking, screen access, camera assistance and Face light, displays, interaction blocking, removal and brightness behavior, coverage, independent onset angles, full angle, appearance, fine tuning, and enable/pause controls. It does not change your effect preferences or grant permissions. Initial sensor startup waits until the tour finishes or is skipped; any previously owned brightness restoration still runs immediately. Light and dark appearances use native materials, and Reduce Motion removes the entrance and scroll movement.

`bash scripts/test-settings-tour-ui.sh` renders all steps at regular and minimum window sizes in both appearances. These offscreen native renders exercise layout without opening the camera, starting AirPods tracking, or capturing the desktop.

## Notch recenter coach

Hover near the notch to reveal **Set center**, **Enable/Pause**, and settings. **Show Notch Controls** in the AirVeil menu is an alternative to hovering. With camera assistance enabled, checks show a circular mirrored preview beneath the hardware cutout. Face straight ahead, within **5° of camera-forward**, and hold briefly. One continuous camera check both verifies that pose and aligns AirPods; it does not restart for a second scan or ask for a calibration turn.

The curved indicator shows camera-estimated deviation from straight ahead. A previously verified camera sign permits AirPods updates between camera scans. When no direction mapping is known, the indicator shows unsigned distance from center without inventing left/right. Starting a check at 13° does not display or establish a new zero. Headphone motion after a completed check remains relative to the accepted center; the ±5° acceptance buffer also bounds the possible zero error from accepting a slightly turned pose.

The check needs three distinct centered observations and fresh, stationary AirPods evidence on both sides of their capture times. It targets roughly two seconds under good conditions; camera startup, lighting, and movement can lengthen it. Progress reflects accepted evidence, and success requires a valid alignment. Leaving the ±5° yaw region clears the hold. This is a threshold on the camera's pose estimate, not a measured physical-accuracy guarantee. Camera images are released on stop, cancel, timeout, and sleep.

**Face light** is AirVeil’s own rounded rectangular screen-edge illumination. It starts automatically after two distinct, consecutive camera frames confirm a close face is too dark to read. Empty darkness, a distant face, or a measurable off-center pose does not trigger it. The notch offers an Off control; switching it off prevents automatic relighting during that check. Success, cancellation, stale/missing face evidence, and inactivity turn it off. It never changes display brightness or Apple’s independent Edge Light preference. See the [Face light flow](research/FACE-LIGHT-FLOW.md).

The first notch appearance opens a four-step tour of head tracking, centering, Face light, and controls. Back and Next navigate; only **End tutorial** records completion. Clicking elsewhere leaves it open. Sleep temporarily hides it, and an unfinished tour returns at the next notch appearance after relaunch. Tutorial illustrations do not start the camera or illuminate the display.

The native panel grows down from the physical notch into a compact rounded camera-and-rail card. A successful check transitions through green loops into a stroked smile before retracting. It keeps important content outside the dead camera cutout and does not become the key window. It selects the notched display even when an external monitor is the main display, with a floating top-center fallback on unnotched screens. Reduce Motion removes springs and scale motion. Settings remain available for advanced controls, and subsequent startup keeps them hidden after the first-launch tour. Use `open /Applications/AirVeil.app --args --settings` for explicit settings at launch.

**Preview Notch Animation** in the AirVeil menu shows a labeled demonstration without starting a camera check or changing calibration. Cancel closes it. This preview is a visual demonstration, not sensor validation.

Run `bash scripts/test-notch-ui.sh` for geometry and native controller lifecycle checks plus 22 notch states rendered at 2x in `build/notch-previews/`. The regular test script covers the camera/coach evidence, low light, crop mapping, preview lifetime and cancellation. [Notch engineering research](research/NOTCH-RESEARCH.md), the [reference motion study](research/NOTCH-MOTION-STUDY.md), and the [tracking repair investigation](research/NOTCH-TRACKING-REPAIR.md) document the implementation decisions.

## Setup

1. Connect and wear the AirPods on this Mac.
2. AirVeil detects connected, worn AirPods automatically. Allow Motion access when requested.
3. Face the center of the display and choose **Set center**. In manual mode, repeat this after removal, a motion gap, or a lost sensor reference. The optional camera setup below is intended to restore the original direction without repeating this step; its physical accuracy is still being tested.
4. Confirm in the preview that a physical left turn obscures the right side. Use **Invert direction** if needed.
5. Choose **Allow screen capture** and enable AirVeil in the macOS privacy settings. Reopen the app if macOS requests it. Subsequent builds use the same signing identity to preserve this approval.
6. Choose **Enable desktop effect**.

### Optional camera assistance

Camera assistance is **off by default**. Enable it explicitly in settings to request Camera access. The app uses only the built-in Mac camera, processes images locally in memory, and does not select an iPhone or external camera automatically.

For first-time setup, face the Mac camera straight ahead and choose **Set center**. Keep your estimated yaw within ±5° and hold briefly. The same accepted camera and AirPods evidence completes setup in one pass. A turned pose outside that buffer cannot be saved as center. Older versions that saved an arbitrary camera angle require one deliberate Set center to migrate; their old angle cannot silently become the new straight-ahead reference.

After a confirmed in-ear removal and return, face straight ahead again for one brief check. Idle audio, device handoffs, and sensor resets pause tracking without starting another camera check; choose **Refresh direction** or **Enable blur** when ready. A startup or confirmed-return check gets one attempt, including if interrupted by another sensor epoch. A check at 13° or 15° stays pending until you return within the center buffer. Recovery preserves the saved camera configuration and updates only the current sensor alignment. Checks stop on success or within 12 seconds, with a 20-second setup limit to allow time to find the camera and lighting controls. If a check cannot finish, the effect stays paused; **Refresh direction** retries, while **Set center** establishes a new setup after camera or display changes. Pause, sleep, and inactivity cancel camera work.

The camera only establishes a centered pose; AirPods then track rotation. It is not an off-axis recovery system. Large turns, tilt, a poor view, multiple faces, or insufficient light can prevent acceptance. Keep the camera and display fixed. Physical direction and perceived speed still need a wearer check after changes to the algorithm.

**Pause & Clear Screen** in the menu bar immediately removes all overlays. The app also registers **Control–Option–Command–P** as a global pause shortcut and reports when registration fails. Quitting removes the effect.

The preview slider uses a synthetic sample desktop and requires no screen capture. Its simulation is separate from live sensor verification.

## Stable permissions across updates

Builds reuse one certificate and private key in a dedicated keychain under `~/Library/Application Support/AirVeil/Signing`, outside this repository. The keychain password is a random value stored in that private directory for local build automation. Do not share this directory or delete it between builds. The build fails if its identity is missing; it never silently falls back to ad hoc signing. The signing helper temporarily includes this keychain in the user search list, restores the original list, and locks it afterward. It does not add a trusted root or change system trust settings.

Migrating from an older ad hoc build requires one new macOS screen-capture approval for the persistent identity. The app checks actual ScreenCaptureKit access; the preflight indicator alone no longer prevents capture. macOS still controls consent and may require it again after revocation, an identity replacement, or OS policy changes. This local certificate is for development on this Mac, not a notarized public release.

## Controls and behavior

- **Directional half / Whole-screen sweep** selects opposite-half blur or a moving blur edge across the full display. Turning left starts at the right edge and sweeps left; turning right mirrors it. At the full-effect angle, the entire display is blurred.
- **Displays** shows connected displays and lets you choose which ones receive blur. Selection is saved by stable display identity. **Check displays** refreshes the list. Changing selection pauses the effect.
- **Block clicks and scrolling while blurred** intercepts pointer input in the blurred area or the entire affected display. AirVeil settings, the menu bar, and the global pause key remain available. Keyboard focus is unchanged.
- **Automatically manage displays when AirPods are removed** is an optional, separate control that works even while blur is paused. After live headphone motion has been received, validated loss of an in-ear bud starts the removal policy after a 1.5-second reinsertion delay. A Core Motion disconnect is only transport evidence and cannot start removal behavior. Keep Automatic Ear Detection enabled. Per-bud metadata supplies removal evidence when supported, so removing the nonstreaming bud can also trigger the check. A known per-bud removal persists across transport reconnects until a stable worn-bud gain or explicit manual recovery. Motion gaps and calibration jumps alone do not trigger removal.
- **Dim while I am still seated** uses the most recent successful center check to remember anonymous foreground seat geometry for this app session. With camera assistance enabled, the built-in camera remains active at 3 analyses/second while AirPods are removed. A foreground body can remain present while turned away; smaller background or side occupants are excluded. Confirmed presence dims the built-in panel to the adjustable 0–50% target (0% default, black without locking) and prevents idle display sleep. Reinserting a removed bud stops presence capture and restores the original brightness before camera heading recovery. The upgrade starts at 0% and retains the previous version’s brightness preference under its old key for rollback. External displays are not dimmed.
- Confirmed departure keeps an already dimmed panel at its current level through the existing display-off action, avoiding a flash before sleep. Ambiguity, darkness, or missing camera evidence has an 8-second grace period; no usable seat reference falls back to display off. Use **Set center** after launching or moving the Mac to refresh the seat. Confirmed departure is latched for that removal episode. Geometry cannot distinguish somebody silently replacing the wearer in the same seat; it is not identity verification.
- Brightness restoration retains the original level through slider changes, and a small persistent journal recovers interrupted writes. A manual brightness adjustment takes precedence. Pause, disabling the feature, and normal quit restore owned brightness; asleep or inactive sessions defer restoration until wake/unlock.
- Automatic display off uses macOS display sleep without changing the Mac’s lock or power preferences. Whether a password is required on wake follows **System Settings → Lock Screen → Require password after screen saver begins or display is turned off**. Choose **Immediately** for password protection. AirVeil never unlocks the Mac on reconnection. The app's **Lock Screen settings** button opens that page.
- **Reset defaults** restores effect settings, selects all connected displays, disables camera assistance and automatic display off, and pauses the effect. It does not revoke macOS permissions or replace saved calibration values.
- **Start blur when turning** has independent Left and Right controls, each from 0–60°. Drag the semicircular dial; its illustrated head only turns into the selected side. Keyboard/accessibility adjustments use one-degree steps. The default is 8° on each side; full effect is 32°. Increasing onset beyond the full-effect threshold raises that threshold to preserve a usable transition.
- Adjustable blur, edge feather, and response time.
- **Opaque cover** removes source color at full strength for stronger obscuration.
- AirPods motion starts after the first-launch tour is completed or skipped, and automatically at subsequent launches and resumes the existing stream on reconnection. Initial startup stalls and actual stream errors retry with a bounded delay. Once a center exists, silence alone does not restart its stream: if motion stays unavailable, the app asks you to reconnect AirPods or restart AirVeil, with Set center required after a restart in manual mode, or a fresh alignment in camera mode.
- In **manual mode**, removal, stale input, a detected reference jump, source/clock change, or stream restart invalidates the usable center. Its copied value is retained for diagnostics, but cannot drive blur until an explicit **Set center**. App relaunch also requires a manual center. Stillness never silently chooses a new zero.
- With **camera assistance**, the saved centered-camera configuration survives sensor resets. Each new sensor epoch needs one fresh facing-center check before its heading can drive blur. The current implementation uses one reference direction for the selected displays; it does not infer each monitor’s physical angle.
- Lost or invalid tracking automatically pauses the effect and clears blur and input blockers. A previously active effect can resume after a valid manual center or camera alignment and an active Mac session. Explicit Pause, display selection change, or reset cancels that resume intent. Capture failures also pause and clear. The normal desktop is visible while paused.
- Starting a drag before blur appears may leave that already-started drag with the underlying app; the blockers intercept newly delivered pointer events in covered regions.
- Sleep or session resignation pauses the effect, discards desktop frames, and stops camera checks. The motion service can remain available, but an unobserved gap invalidates its manual reference. Camera mode requires a new alignment on return. A manually paused effect stays paused after wake.
- Display off is requested once per removal. Confirmed reinsertion during the delay, pressing Pause, switching this setting off, or quitting cancels a pending request. Waking while the AirPods remain absent does not immediately turn the displays off again. Reset defaults disables this option.
- An actual display layout change requires rebuilding capture with a deliberate pause/re-enable. Repeated notifications for an unchanged layout do not pause tracking. Enable can retry a saved camera reference after a recoverable interruption without redefining center. A verified continuous sensor stream can survive delayed UI delivery; real acquisition gaps still invalidate it.

## Privacy and platform limits

Motion, desktop frames, and optional camera images are processed locally, in memory. Camera setup persists only small numeric calibration/configuration records; the seat reference is temporary geometry in memory. Brightness recovery stores only the display identifier and numeric brightness values; it does not save face images or biometric templates. Temporary motion/pose buffers are bounded and remain in RAM. Headphone acquisition runs separately from UI work, and the app coalesces outdated visual poses while retaining real sensor continuity failures. The app captures no audio, runs no server, and includes no analytics or cloud inference. Its own windows are excluded from its capture streams to prevent repeated blur feedback. It does not save recordings.

Software blur changes the same pixels for everyone looking at the display. It is not an optical privacy filter, does not identify bystanders, and does not guarantee unreadability of all content. Transition edges are partly visible. Secure macOS surfaces and every fullscreen application are not guaranteed to be covered.

The wearer physically confirmed that the retained AirPods reference produced the wrong zero after removal and reinsertion while looking left or right. Manual mode therefore refuses that unverified reference. Camera assistance adds a fixed visual reference, not absolute compass heading or eye gaze. It estimates mostly horizontal head turns with conservative face and tilt limits. Camera capture timestamps are converted to the Mac host clock, but the AirPods source clock relationship is not established; the prototype uses a steady overlap window with an assumed 200 ms timing guard. This assumption and camera pose accuracy remain physical validation requirements. A camera identifier also cannot detect every physical camera or seating change.

iPhone and iPad support headphone motion, but a normal app cannot reproduce this arbitrary system-wide overlay across other apps. A future mobile implementation would need an explicitly limited app-owned content surface. The implemented target is macOS.

Per-bud wear status uses runtime-checked, read-only private IOBluetooth getters on a utility queue. A unique connected compatible AirPods device and stable evidence are required; unsupported or stale metadata leaves automatic removal waiting for evidence. This can miss removal when the headset disconnects before reporting its in-ear change; it avoids treating idle audio or device handoff as removal. Ear monitoring is active when either camera assistance or automatic display management is enabled. No scanning, pairing, connection changes, identifiers, or wear history are saved. Bluetooth permission may be requested by macOS. See the [per-bud and zero-brightness review](research/REMOVAL-ZERO-REVIEW.md).

Built-in brightness control uses a runtime-checked private DisplayServices interface on Apple silicon, with an available IOKit fallback. It is not a public-API or future-OS compatibility guarantee; unsupported control is reported explicitly. Lock-state compatibility notifications are checked against the current session before resuming; AirVeil never wakes or unlocks the Mac. See [presence API research](research/PRESENCE-REMOVAL-RESEARCH.md).

## Energy work

Current source changes isolate motion telemetry and animated strengths from the full settings view, publish small tracking snapshots only when displayed values change, suspend hidden previews, and draw on demand. The animation clock rests after the effect settles. Transparent output and genuinely solid opaque output bypass unnecessary source copying and Gaussian blur work; intermediate blur still processes the source it needs.

Native desktop capture/output resolution and the requested maximum 60 fps capture cadence are unchanged. Lower-resolution blur levels and lower content refresh rates remain research options. These changes target unnecessary work; no measured energy or battery-life saving is claimed yet. Before/after runtime measurement and visual validation are still required.

## Research and validation

The [latest notch motion study](research/NOTCH-REDESIGN-STUDY.md) records frame-by-frame reference analysis. [Proposed next features](research/NEXT-FEATURES.md) ranks a guided setup rehearsal and named workspace profiles; these proposals are not included in the current update.

The [feature opportunity report](research/FEATURE-RESEARCH-2026-09.md) evaluates eight additional privacy, reliability, and usability ideas against macOS APIs and the 0.13.0 release. It includes ranked recommendations, proposed flows, and validation gates; no proposed features are implemented.

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
