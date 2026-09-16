# AirVeil

**[Download AirVeil 0.14.0 RC 1 — macOS DMG](https://github.com/ShivHax-YT/AirVeil/releases/download/v0.14.0-rc.1/AirVeil-0.14.0-apple-silicon.dmg)** · [Latest release and installation notes](https://github.com/ShivHax-YT/AirVeil/releases/latest)

**Source version: 0.15.0, build 31.** Build 31 is installed and verified locally. Enable blur is the main notch action, with Set center on the right. Focused native checks and release packaging pass; build 30's full behavioral regression remains recorded. The wearer confirmed seated dimming/restoration and the direct notch wait → alignment → automatic-blur flow. Automatic departure/repeated brightness recovery and low-light recheck acceptance remain pending. See the [whole-task checklist](validation/GOAL-CHECKLIST-0.15.0-31.md). The download above remains published **0.14.0 RC 1**; build 31 is not a published release.

AirVeil is a native macOS app with Dock, Settings, and menu-bar controls. It uses AirPods head motion to progressively obscure the opposite side of your desktop. Turn left to blur the right side; turn right to blur the left. The untouched side stays transparent. Clicks and scrolling are blocked in blurred areas by default, with a control to block the entire affected display instead.

## Download

The existing published download is [AirVeil 0.14.0 RC 1](https://github.com/ShivHax-YT/AirVeil/releases/tag/v0.14.0-rc.1). Open its matching `.dmg`, drag AirVeil into Applications, then launch AirVeil from Applications. It is an Apple silicon release candidate for macOS 14 or later; hardware acceptance is still pending. It is development-signed, not Apple-notarized, so macOS may block its first launch on another Mac. Repository access is required while this repository is private.

Build the current 0.15.0 distributable locally with `bash scripts/package-dmg.sh`; it produces a DMG and SHA-256 checksum under `build/releases/`. The package includes the app with its bundled legal documents, an Applications shortcut, and installation notes. Maintainer preferences, diagnostic files, and signing secrets are excluded. Packaging does not publish a GitHub release.

## Requirements

- macOS 14 or later and a Metal-capable Mac.
- AirPods with dynamic head tracking; AirPods Pro 3 are the initial hardware test target.
- Head Tracking uses macOS **Motion & Fitness** access; live desktop blur uses **Screen Recording** access.
- Optional camera assistance needs the Mac’s built-in camera and **Camera** access. You can enable it in permission setup or Settings. **Sync head** and **Enable blur** while waiting for AirPods also explicitly request camera alignment once fresh motion is available; macOS permission is required before capture.
- These are the three permissions explained by AirVeil. It does not request Bluetooth or microphone access, or inspect private per-ear Bluetooth metadata.
- Xcode Command Line Tools to build. Full Xcode's offline Metal compiler is not required.

## Build and run

```sh
# Once per Mac, before the first build:
python3 scripts/setup-signing.py
./scripts/install.sh
```

This builds an app for the current Mac's architecture, signs it with a persistent local development identity, installs it at `/Applications/AirVeil.app`, and opens permission setup before the Settings tour. The new setup also appears after upgrading if it has not been completed. AirVeil appears in the Dock and Command-Tab, with quick controls in the menu bar. Once setup and the tour are complete, later launches keep Settings closed until requested. An existing AirVeil install is retained in the ignored build directory. The build script prefers the installed macOS 26.5 SDK to avoid a missing SwiftUI macro plugin in this Mac's default SDK; set `AIRVEIL_SDK` to use another complete SDK.

To build without installing, run `./scripts/build.sh`. The default release configuration defines `AIRVEIL_RELEASE`, writes `build/AirVeil.app`, and excludes **Preview Notch Animation** menu commands. For those developer previews, run `./scripts/build.sh --development`; it defines `AIRVEIL_DEVELOPMENT` and writes a separate `build/development/AirVeil.app`. The installer and DMG scripts always use the default release output. Both configurations use the local development signing identity; “release configuration” does not mean Apple notarization.

Open `/Applications/AirVeil.app` and choose Settings from the menu bar or Dock to return later.

## Settings tabs

Settings has five tabs, with Enable/Pause available in the header:

| Tab | Controls |
|---|---|
| **Preview** | Example desktop, simulated turns, tracking status, and pause guidance |
| **Tracking** | Head-tracking status, Set center, camera assistance, Refresh direction, and Face light |
| **Displays** | Screen Recording access, selected displays, and click/scroll blocking |
| **Appearance** | Coverage, left/right onset angles, full angle, blur styling, and fine tuning |
| **Power** | Automatic display management, seated dimming target, and energy use |

**Sync head**, beneath the onset illustration in Appearance, requests a real camera and AirPods alignment. Face the camera and hold still for the check. After it succeeds, the head, green arc marker, arc fill, and large degree readout follow your left and right turns independently of the selected onset side and **Invert direction**. This live view is read-only; **Stop sync** returns the dial to editing the saved blur starting angles. While waiting for valid tracking, it shows no angle or marker. The marker stops at the arc’s 60° limit, with an explanation when the actual readout exceeds it. Sync does not start desktop blur by itself; if blur was already active, it can resume after valid alignment. Leaving Appearance, closing Settings, or minimizing Settings stops the live view. If Head Tracking access is missing, review Permissions and press Sync head again.

## Permission setup and first-launch tour

Version 0.15.0 starts with a welcome and three permission cards: **Camera**, **Screen Recording**, and **Head Tracking**. Each explains why access is useful, when it runs, what stays local, and what continuing without it means. Read to the end before requesting access; you can continue without any permission. AirVeil checks the actual macOS result before marking access allowed. Reviewing setup does not start a camera check or desktop effect. A Head Tracking request may briefly start and stop a motion session to obtain the OS decision. Closing setup preserves its progress without completing it. **Permissions** in Settings reopens these cards.

The permission stage uses a light frosted reading card over a quiet field of small white stars with short meteor streaks every 4.5 seconds. macOS 26 or later uses native Liquid Glass for primary actions. Stable card dimensions and short, interruptible transitions keep reading and navigation responsive; lightweight side previews show the neighboring permission. Core Animation drives the sky without a fixed frame-rate loop and suspends it while hidden or fully covered. Reduce Motion keeps the background still and removes card movement, while Reduce Transparency gives the reading card a solid surface. See [UI implementation and validation](research/FLUID-SETTINGS-UI.md) for measured checks and remaining display-verification limits.

After the permission summary, **Start the tour** opens the 16-step Settings spotlight tour. Each step selects its tab, then highlights and scrolls the actual control into view while the rest of Settings dims. Back, Continue, Close tour, and Get started support a self-paced walkthrough. Closing Settings during the tour dismisses that tour. **Take a tour** replays it later. Setup choices and tour completion are saved per macOS user and survive app updates. Downloading or copying the app does not execute it.

The tour covers the preview, head tracking, screen access, camera assistance and Face light, displays, interaction blocking, removal and brightness behavior, energy use, coverage, independent onset angles, full angle, appearance, fine tuning, and enable/pause controls. Tour navigation does not change effect preferences or grant permissions. Highlighted controls and scrolling remain usable; adjusting a real setting applies that setting. The tour demo slider affects only the example image, even while desktop blur is enabled. Ongoing sensor startup requires the Head Tracking choice and waits until the tour finishes or is closed, unless you explicitly start tracking with a control. Previously owned brightness restoration still runs immediately. Light and dark appearances use native materials, and Reduce Motion removes the entrance and scroll movement.

The footer offers **Terms of Use**, **Privacy Policy**, and **Cookies & Local Storage** before any permission request and from Settings afterward. The documents open in native sheets from the app bundle without fetching a webpage. Their external reference/contact links open only when selected. See the [canonical legal documents](docs/legal/README.md).

`bash scripts/test-settings-tour-ui.sh` renders all steps at regular and minimum window sizes in both appearances. These offscreen native renders exercise layout without opening the camera, starting AirPods tracking, or capturing the desktop.

`bash scripts/test-settings-preview.sh` checks actual Metal pixels after simulated turns, normal preview callbacks, Center, and hide/show transitions. It uses an isolated example image and starts no sensors or desktop capture.

## Energy use

Settings offers **Automatic**, **Smoothest**, and **Reduced energy**. Automatic keeps the usual desktop refresh unless macOS reports Low Power Mode or serious/critical thermal pressure. Reduced energy always requests up to 30 desktop frames per second; Smoothest requests up to 60. Actual delivery depends on changing desktop content.

Only desktop capture cadence changes. Head tracking, coverage movement, camera checks, and removal/brightness behavior keep their existing timing. The setting is saved, takes effect on running capture without restarting it, and refreshes system state after wake. If a display rejects an energy update, its working capture continues and Settings explains the failure. No new permission or network service is involved. Battery-life savings have not been measured.

See the [energy implementation research](research/ENERGY-AWARE-IMPLEMENTATION.md) for Apple API evidence, tradeoffs, and validation boundaries.

## Notch recenter coach

Hover near the notch to reveal **Set center**, **Enable/Pause**, and settings. **Show Notch Controls** in the AirVeil menu is an alternative to hovering. With camera assistance enabled, checks show a circular mirrored preview beneath the hardware cutout. Face straight ahead, within **5° of camera-forward**, and hold briefly. One continuous camera check both verifies that pose and aligns AirPods; it does not restart for a second scan or ask for a calibration turn.

If you choose **Enable blur** before fresh AirPods motion is available, the notch shows animated AirPods Pro artwork and **Wear AirPods to continue blurring**. After motion returns, the waiting card yields to the real camera check. Blur starts only after alignment succeeds and Screen Recording access is available. A failed or canceled check leaves blur off and requires an explicit retry. The same waiting card appears while seated-removal monitoring is active and motion is absent.

**×** dismisses the reminder without disabling monitoring; returning AirPods still starts the normal alignment check. A later removal can show the reminder again. **Turn off feature** on that card stops blur and camera checks, cancels the pending start, and restores brightness owned by AirVeil. It pauses automatic removal checks across relaunches; passive AirPods reconnection cannot undo that choice. Use **Enable blur** in the notch or Settings to resume. Explicit **Sync head**, **Set center**, **Refresh direction**, and **Enable camera assistance** actions also re-enable their tracking workflow once its prerequisites are met. Brightness cleanup can continue while the feature is off, and waits for an active, awake Mac if necessary. Reduce Motion keeps the AirPods artwork still.

The curved indicator shows camera-estimated deviation from straight ahead. A previously verified camera sign permits AirPods updates between camera scans. When no direction mapping is known, the indicator shows unsigned distance from center without inventing left/right. Starting a check at 13° does not display or establish a new zero. Headphone motion after a completed check remains relative to the accepted center; the ±5° acceptance buffer also bounds the possible zero error from accepting a slightly turned pose.

The check needs three distinct centered observations and fresh, stationary AirPods evidence on both sides of their capture times. It targets roughly two seconds under good conditions; camera startup, lighting, and movement can lengthen it. Progress reflects accepted evidence, and success requires a valid alignment. Leaving the ±5° yaw region clears the hold. This is a threshold on the camera's pose estimate, not a measured physical-accuracy guarantee. Camera images are released on stop, cancel, timeout, and sleep.

**Face light** is AirVeil’s own rounded rectangular screen-edge illumination. It starts automatically after two distinct, consecutive camera frames confirm a close face is too dark to read. Empty darkness, a distant face, or a measurable off-center pose does not trigger it. The notch offers an Off control; switching it off prevents automatic relighting during that check. Success, cancellation, stale/missing face evidence, and inactivity turn it off. It never changes display brightness or Apple’s independent Edge Light preference. See the [Face light flow](research/FACE-LIGHT-FLOW.md).

The first notch appearance opens a four-step tour of head tracking, centering, Face light, and controls. Back and Next navigate; only **End tutorial** records completion. Clicking elsewhere leaves it open. Sleep temporarily hides it, and an unfinished tour returns at the next notch appearance after relaunch. Tutorial illustrations do not start the camera or illuminate the display.

The native black surround expands from the physical notch to the left, right, and down together over 0.56 seconds. Its rounded edges grow around the camera-and-rail card while the camera, rail, and face-check glyph retain their size. Decorative side extensions pass pointer input through to the menu bar. A successful check transitions through green loops into a stroked smile before retracting. It keeps important content outside the dead camera cutout and does not become the key window. It selects the notched display even when an external monitor is the main display, with a floating top-center fallback on unnotched screens. Reduce Motion removes springs and scale motion. Settings remain available for advanced controls, and subsequent startup keeps them hidden after the first-launch tour. Use `open /Applications/AirVeil.app --args --settings` for explicit settings at launch.

In a `--development` build only, **Preview Notch Animation** in the AirVeil menu shows a labeled demonstration without starting a camera check or changing calibration. Cancel closes it. This preview is a visual demonstration, not sensor validation. It is absent from the default release build and packaged DMG.

Run `bash scripts/test-notch-ui.sh` for geometry and native controller lifecycle checks plus 31 notch states rendered at 2x in `build/notch-previews/`. The regular test script covers the camera/coach evidence, low light, crop mapping, preview lifetime and cancellation. [Notch engineering research](research/NOTCH-RESEARCH.md), the [reference motion study](research/NOTCH-MOTION-STUDY.md), and the [tracking repair investigation](research/NOTCH-TRACKING-REPAIR.md) document the implementation decisions.

Settings stays at the normal window level, appears in the Window menu, and restores from the Dock after minimizing or closing. Notch animations and Face light remain above ordinary application windows. `bash scripts/test-window-presentation.sh` checks native window behavior.

## Setup

1. Connect and wear the AirPods on this Mac.
2. Review the three permission cards. Allow Head Tracking to use AirPods motion; allow Camera if you want camera assistance, and Screen Recording if you want live desktop blur. Declining a permission leaves its dependent features off.
3. Face the center of the display and choose **Set center**. In manual mode, repeat this after removal, a motion gap, or a lost sensor reference. The optional camera setup below is intended to restore the original direction without repeating this step; its physical accuracy is still being tested.
4. Confirm in the preview that a physical left turn obscures the right side. Use **Invert direction** if needed.
5. If Screen Recording is still unavailable, choose **Allow screen capture** and enable AirVeil in the macOS privacy settings. Reopen the app if macOS requests it. Subsequent builds reuse the same signing identity; macOS remains responsible for permission decisions.
6. Choose **Enable blur**.

### Optional camera assistance

Camera assistance is optional. Choose it during permission setup or use **Enable camera assistance** in Settings to request Camera access. A new install keeps it off if you continue without camera access. Explicitly choosing **Sync head**, or **Enable blur** while waiting for AirPods, can request camera assistance for that alignment workflow when motion returns. The app uses only the built-in Mac camera, processes images locally in memory, and does not select an iPhone or external camera automatically.

For first-time setup, face the Mac camera straight ahead and choose **Set center**. Keep your estimated yaw within ±5° and hold briefly. The same accepted camera and AirPods evidence completes setup in one pass. A turned pose outside that buffer cannot be saved as center. Older versions that saved an arbitrary camera angle require one deliberate Set center to migrate; their old angle cannot silently become the new straight-ahead reference.

When fresh motion returns after a removal-related interruption, face straight ahead again for one brief check. A sustained motion gap after a successful check permits one recovery attempt on return. Failed or interrupted attempts do not retry on every sensor epoch; choose **Refresh direction** or **Enable blur** to try again. A connection change does not prove which AirPod was removed. A check at 13° or 15° stays pending until you return within the center buffer. Recovery preserves the saved camera configuration and updates only the current sensor alignment. Checks stop on success or within 12 seconds, with a 20-second setup limit to allow time to find the camera and lighting controls. If a check cannot finish, the effect stays paused; **Refresh direction** retries, while **Set center** establishes a new setup after camera or display changes. Pause, sleep, and inactivity cancel camera work.

The camera only establishes a centered pose; AirPods then track rotation. It is not an off-axis recovery system. Large turns, tilt, a poor view, multiple faces, or insufficient light can prevent acceptance. Keep the camera and display fixed. Physical direction and perceived speed still need a wearer check after changes to the algorithm.

**Pause & Clear Screen** in the menu bar immediately removes all overlays. The app also registers **Control–Option–Command–P** as a global pause shortcut and reports when registration fails. Quitting removes the effect.

The preview slider uses a synthetic sample desktop and requires no screen capture. Its simulation is separate from live sensor verification.

## Stable permissions across updates

Builds reuse one certificate and private key in a dedicated keychain under `~/Library/Application Support/AirVeil/Signing`, outside this repository. The keychain password is a random value stored in that private directory for local build automation. Do not share this directory or delete it between builds. The build fails if its identity is missing; it never silently falls back to ad hoc signing. The signing helper temporarily includes this keychain in the user search list, restores the original list, and locks it afterward. It does not add a trusted root or change system trust settings.

Migrating from an older ad hoc build requires one new macOS screen-capture approval for the persistent identity. The app checks actual ScreenCaptureKit access; the preflight indicator alone no longer prevents capture. macOS still controls consent and may require it again after revocation, an identity replacement, or OS policy changes. This local certificate is for development on this Mac, not a notarized public release.

## Controls and behavior

- **Directional half / Whole-screen sweep** selects opposite-half blur or a moving blur edge across the full display. Turning left starts at the right edge and sweeps left; turning right mirrors it. At the full-effect angle, the entire display is blurred.
- **Displays** shows connected displays and lets you choose which ones receive blur. Selection is saved by stable display identity. **Check displays** refreshes the list. Changing selection pauses the effect.
- **Block clicks and scrolling while blurred** intercepts pointer input in the blurred area or the entire affected display. The notch, menu bar, and global pause key remain available. Settings behaves like an ordinary desktop window and can be covered by the effect. Keyboard focus is unchanged.
- **Lock when I leave** and **Dim while I stay seated** are independent switches in Power. Locking defaults on; dimming defaults off until explicitly enabled. An existing saved lock-off choice is preserved. Upgrading does not treat the old automatically persisted dimming flag as an opt-in. Both options need camera assistance and a successful center check. With both switches off, removal starts neither seat monitoring nor a display action. **Turn off feature** overrides both until explicitly re-enabled.
- After a stable wearing session, sustained headphone-motion loss starts a short return delay and then a local seat check. Keep Automatic Ear Detection enabled. The public motion signal cannot identify individual earbuds or prove both are out: a sustained connection interruption can produce the same signal. Removing one bud while the other supplies continuous motion, a continuous left/right source handoff, or a brief interruption does not trigger the workflow. Fresh returning motion stops the check; a stable motion session is needed to arm another removal.
- **Dim while I stay seated** uses the latest successful center check's temporary foreground-seat geometry. Confirmed presence dims the built-in panel to the chosen 0–50% target and prevents idle display sleep. The target defaults to 0%, but dimming itself is off by default. Body evidence can establish presence even while the person turns away; smaller background or side occupants do not replace that foreground track. External displays are not dimmed. Turning the dim switch off restores owned brightness while keeping the seat check active if locking is still enabled.
- If dimming makes the camera view too dark, the notch explains why brightness will be restored, then shows **Brightness restored** and returns to a seat-check visual. Brightness is restored once and stays unchanged for the rest of that removal episode, including if the dim target changes. Camera monitoring continues through the transition. Fresh dark frames never prove absence; other invalid evidence, stale capture, and camera failures retain bounded cleanup. A true 0% backlight can hide the initial notice, so the explanation remains visible after restoration.
- **Lock when I leave** requests display sleep only after valid empty-seat evidence. With locking off, an empty seat does not request sleep. Turning both switches off stops removal monitoring and restores owned brightness. Missing camera assistance or a seat reference never falls back to immediate sleep. Use **Set center** after moving the Mac. Seat geometry is not identity verification and cannot distinguish someone silently replacing the occupant.
- Brightness restoration retains the original level through slider changes, and a small persistent journal recovers interrupted writes. Readings from an asleep display cannot replace the saved baseline. Recorded dims retained through suspension keep their ownership until recovery, and a lock interrupting restoration leaves the journal pending. Heading recovery waits for brightness cleanup. During ordinary awake dimming, a manual brightness adjustment still takes precedence. Pause, disabling the feature, and normal quit restore owned brightness; asleep or inactive sessions defer restoration until wake/unlock. Installed build 27 waits three seconds, then requires consistent awake brightness readings before resuming, including when no journal exists. New dims begun within 15 seconds of stabilization retain wake ownership. Unsettled readings leave recovery pending for retry. Four wearer-confirmed tests restored original brightness across both return orders after manual lock and actual Apple-menu Sleep. Automatic departure sleep remains unverified in the current low-light setting; build 28 adds the one-time restore-and-continue behavior described above, with physical acceptance still pending.
- Automatic display off uses macOS display sleep without changing the Mac’s lock or power preferences. Whether a password is required on wake follows **System Settings → Lock Screen → Require password after screen saver begins or display is turned off**. Choose **Immediately** for password protection. AirVeil never unlocks the Mac on reconnection. The app's **Lock Screen settings** button opens that page.
- **Reset defaults** restores effect settings, selects all connected displays, disables camera assistance and dimming, enables the locking preference, and pauses the effect. Camera assistance and a center check are still required for removal actions. It does not revoke macOS permissions or erase saved camera setup, tutorial completion, or permission-setup records.
- **Start blur when turning** has independent Left and Right controls, each from 0–60°. Drag the semicircular dial; its unsynced illustration demonstrates the selected side. **Sync head** makes the head, arc marker, and degree readout follow live camera-aligned AirPods motion. Stop sync to edit either threshold. Keyboard/accessibility adjustments use one-degree steps in editing mode. The default is 8° on each side; full effect is 32°. Increasing onset beyond the full-effect threshold raises that threshold to preserve a usable transition.
- Adjustable blur, edge feather, and response time.
- **Opaque cover** removes source color at full strength for stronger obscuration.
- After Head Tracking is allowed in permission setup, AirPods motion starts when the first-launch tour is completed or closed, or when you explicitly start tracking in the tour. It starts automatically at subsequent launches and resumes the existing stream on reconnection. Continuing without Head Tracking leaves automatic startup off; revisit **Permissions** to enable it. Initial startup stalls and actual stream errors retry with a bounded delay. A known center or a latched removal keeps silence from automatically restarting its stream. If motion stays unavailable, the app asks you to reconnect AirPods or restart AirVeil, with Set center required after a restart in manual mode, or a fresh alignment in camera mode.
- In **manual mode**, removal, stale input, a detected reference jump, source/clock change, or stream restart invalidates the usable center. Its copied value is retained for diagnostics, but cannot drive blur until an explicit **Set center**. App relaunch also requires a manual center. Stillness never silently chooses a new zero.
- With **camera assistance**, the saved centered-camera configuration survives sensor resets. Each new sensor epoch needs one fresh facing-center check before its heading can drive blur. The current implementation uses one reference direction for the selected displays; it does not infer each monitor’s physical angle.
- Lost or invalid tracking automatically pauses the effect and clears blur and input blockers. A previously active effect can resume after a valid manual center or camera alignment and an active Mac session. Explicit Pause, display selection change, or reset cancels that resume intent. Capture failures also pause and clear. The normal desktop is visible while paused.
- Starting a drag before blur appears may leave that already-started drag with the underlying app; the blockers intercept newly delivered pointer events in covered regions.
- Sleep or session resignation pauses the effect, discards desktop frames, and stops camera checks. The motion service can remain available, but an unobserved gap invalidates its manual reference. Camera mode requires a new alignment on return. A manually paused effect stays paused after wake.
- Display sleep is requested once per motion-loss episode. Fresh motion returning during the delay, pressing Pause, switching this setting off, or quitting cancels a pending request. Waking without a new wearing session does not immediately turn the displays off again. Reset defaults enables the locking preference and leaves dimming off.
- An actual display layout change requires rebuilding capture with a deliberate pause/re-enable. Repeated notifications for an unchanged layout do not pause tracking. Enable can retry a saved camera reference after a recoverable interruption without redefining center. A verified continuous sensor stream can survive delayed UI delivery; real acquisition gaps still invalidate it.

## Privacy and platform limits

Motion, desktop frames, and optional camera images are processed locally, in memory. Saved camera setup contains the camera identifier, display layout/configuration, and numeric calibration; the seat reference is temporary geometry in memory. Brightness recovery stores the display identifier, original/applied/pending brightness values, creation time, and whether a dim must be restored after suspension. Effect preferences, selected displays, tutorial completion, and permission-setup progress also persist. The app saves no camera, desktop, or audio recording and creates no face-recognition identity template. Temporary motion/pose buffers are bounded and remain in RAM. Headphone acquisition runs separately from UI work, and the app coalesces outdated visual poses while retaining real sensor continuity failures.

The app contains no Internet client/server, analytics SDK, advertising, or cloud inference. Its veil, notch, and illumination windows are excluded from capture to prevent repeated blur feedback. Only the registered Settings window is included from AirVeil's own windows, so it behaves like an ordinary desktop window. Explicit `--diagnostics <path>` mode writes a local JSON status snapshot about every half-second; it can include settings, sensor values, counters, states, and errors, but no image/audio frames. It is not automatically uploaded. Uninstalling can leave preferences and diagnostic files behind; Reset defaults is not complete data erasure. See the [Privacy Policy](Resources/Legal/PRIVACY.md) and [Cookies & Local Storage](Resources/Legal/COOKIES.md) for retention, support email, external services, and controls.

Software blur changes the same pixels for everyone looking at the display. It is not an optical privacy filter, does not identify bystanders, and does not guarantee unreadability of all content. Transition edges are partly visible. Secure macOS surfaces and every fullscreen application are not guaranteed to be covered.

The wearer physically confirmed that the retained AirPods reference produced the wrong zero after removal and reinsertion while looking left or right. Manual mode therefore refuses that unverified reference. Camera assistance adds a fixed visual reference, not absolute compass heading or eye gaze. It estimates mostly horizontal head turns with conservative face and tilt limits. Camera capture timestamps are converted to the Mac host clock, but the AirPods source clock relationship is not established; the prototype uses a steady overlap window with an assumed 200 ms timing guard. This assumption and camera pose accuracy remain physical validation requirements. A camera identifier also cannot detect every physical camera or seating change.

iPhone and iPad support headphone motion, but a normal app cannot reproduce this arbitrary system-wide overlay across other apps. A future mobile implementation would need an explicitly limited app-owned content surface. The implemented target is macOS.

Version 0.15.0 removes the private IOBluetooth wear-state reader and Bluetooth permission request. The both-AirPods workflow uses public Core Motion availability, timing, and connection signals. It cannot reliably detect removing only one bud while motion continues from the other, or distinguish complete removal from a sustained connection loss. The [earlier per-bud and zero-brightness review](research/REMOVAL-ZERO-REVIEW.md) records a previous approach; its private-metadata implementation is no longer current. Automated motion tests and simulated camera results do not prove physical removal/reinsertion behavior on a particular headset.

Built-in brightness control uses a runtime-checked private DisplayServices interface on Apple silicon, with an available IOKit fallback. It is not a public-API or future-OS compatibility guarantee; unsupported control is reported explicitly. Lock-state compatibility notifications are checked against the current session before resuming; AirVeil never wakes or unlocks the Mac. See [presence API research](research/PRESENCE-REMOVAL-RESEARCH.md).

## Energy work

Current source changes isolate motion telemetry and animated strengths from the full settings view, publish small tracking snapshots only when displayed values change, suspend hidden previews, and draw on demand. The animation clock rests after the effect settles. Transparent output and genuinely solid opaque output bypass unnecessary source copying and Gaussian blur work; intermediate blur still processes the source it needs.

Native desktop capture/output resolution is unchanged. The Energy use control now requests up to 30 or 60 fps as described above; lower-resolution blur remains a research option. These changes target unnecessary work; no measured energy or battery-life saving is claimed yet. Before/after runtime measurement and visual validation are still required.

## Research and validation

The [latest notch motion study](research/NOTCH-REDESIGN-STUDY.md) records frame-by-frame reference analysis. [Proposed next features](research/NEXT-FEATURES.md) ranks a guided setup rehearsal and named workspace profiles; these proposals are not included in the current update.

The [feature opportunity report](research/FEATURE-RESEARCH-2026-09.md) evaluates eight additional privacy, reliability, and usability ideas against macOS APIs and the 0.13.0 release. It includes ranked recommendations, proposed flows, and validation gates; energy-aware capture is now implemented as described above; the other proposals remain research only.

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
