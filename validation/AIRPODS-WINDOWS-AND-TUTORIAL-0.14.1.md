# AirVeil 0.14.1 (build 19): AirPods events, windows, and tutorial

## Findings from the reported failures

- The installed build received about 50 motion samples/second from the right AirPod while both AirPods were worn, but reported no individual wear state. System Settings confirmed Automatic Ear Detection was on. Read-only legacy Bluetooth probes returned default/unusable ear fields despite a connected, ear-capable device. Those zeros cannot safely be treated as wearing evidence.
- Confirmed removal/reinsertion of the nonstreaming AirPod could leave motion alignment valid, causing the camera coordinator to skip its return check.
- Settings was raised above the notch when blur started. Both `LSUIElement` and the accessory activation policy hid AirVeil from the Dock and Command-Tab.
- The Settings tutorial disabled hit testing, scrolling, and accessibility for the entire settings surface. Its preview highlight excluded the slider and simulation controls.
- A read-only `sysadminctl -screenLock status` check reported an immediate password requirement. No Lock Screen or AirPods system setting was changed.

## Changes

- Confirmed wear transitions invalidate the old direction. Confirmed return and public reconnect permit a fresh camera alignment; a sustained motion gap can permit one retry after a successful alignment. Failed checks do not retry on every sensor epoch.
- When per-ear metadata is unavailable, a debounced public disconnect can request a bounded local seat check with the existing camera/removal/presence options and a valid seat reference. A seated result keeps brightness unchanged; uncertain evidence ends without a display action; confirmed absence can request display sleep. This does **not** establish independent single-AirPod removal or enable seated dimming from a connection change alone.
- Settings uses the normal window level and native Dock/window-cycle behavior. Only the registered Settings window is included in desktop capture; veil, notch, and light surfaces remain excluded. Notch feedback stays above ordinary windows and the other AirVeil surfaces.
- The tutorial has 16 steps with usable highlighted controls, an independent preview slider, separate seated-brightness guidance, native materials, clearer navigation, and corrected copy. Navigating the tour does not change effect preferences; adjusting an actual settings control applies that setting.

## Validation

- `bash scripts/test.sh` passed, including lifecycle, presence, brightness restoration, display-sleep, 690,785 pointer-geometry checks, and actual Metal rendering at 1x/2x. After the final review fixes, targeted AppModel tests passed 295 assertions, camera coordination 131, motion lifecycle 60, and presence coordination 47.
- Window validation passed 10 native Settings checks and 40 capture configuration checks. `bash scripts/test-notch-ui.sh` passed 18 geometry and 45 native lifecycle checks, rendered 27 notch states at 2x, and checked the light border.
- `bash scripts/test-settings-tour-ui.sh` produced all 64 tutorial and 8 energy renders without starting sensors or desktop capture. Compact preview, tracking, camera, onset, seated-brightness, and fine-tuning layouts were visually checked. AppKit bitmap caching omits the Metal example image; these renders alone do not validate its pixels or mouse interaction.
- Build 19 was installed at `/Applications/AirVeil.app`, retaining the previous app in the ignored build directory. Strict signature verification passed and the signing requirement matched the prior installation. Built and installed executable SHA-256: `451951dc517bde7ad3a3fd9ee40bfbcd6fa8caa05fa70a64ffbfbe27f0a844c2`.
- Live startup completed its camera center check, stopped the camera, and reported valid tracking and a current seat reference. Diagnostics confirmed regular application activation, Settings level 0, and notch level 27. The user explicitly confirmed AirVeil appears in both the Dock and Command-Tab.
- Live tutorial track clicking changed the angle from 0 to approximately +44 degrees; Center reset it to 0 while the tour stayed open. All 16 live steps were reached using Continue, and Back returned to the preview step. The installed app was left there for the user's manual slider check.
- `bash scripts/test-settings-preview.sh` passed actual SwiftUI-to-Metal pixel checks using the user's whole-screen/full-angle configuration. The simulated turn changed 284,211 pixel bytes; normal motion callbacks preserved the simulated blur; Center restored exact clear pixels. Hidden updates performed no draws and showing the preview rendered the latest state. The synthetic clear and blurred outputs were visually reviewed. The live capture tool showed an unchanged preview and did not establish dragging; no production rendering bug was reproduced by the direct test, and the user's manual drag/visual confirmation remains pending.

Automated sensor, camera, brightness, and display-sleep tests use injected boundaries; they do not prove physical wearer behavior. Computer Use intermittently returned ScreenCaptureKit errors `-3811`/`-3812` and could not inspect the Dock; those tool errors are separate from the observed successful app camera check and the user's Dock confirmation.

## Remaining hardware boundary

Independent left/right removal and seated blackout remain unverified and unavailable when the headset's per-ear status feed is missing. A public connection event cannot distinguish removal from an audio handoff. Physical removal/reinsertion and departure testing are still required before claiming those behaviors work reliably on this AirPods connection.

Apple documents headphone connect/disconnect behavior with Automatic Ear Detection in [What's new in Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179/). Display sleep follows the Mac's [password-on-wake setting](https://support.apple.com/guide/mac-help/mchlp2270/mac).
