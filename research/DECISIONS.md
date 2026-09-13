# AirVeil architecture decisions

## Platform

Use native Swift, AppKit, SwiftUI, Core Motion, ScreenCaptureKit, and Metal. This avoids a browser-to-native motion bridge and uses public macOS APIs. The initial deployment target is macOS 14.0. On this development Mac use the installed macOS 26.5 SDK explicitly; the default SDK's SwiftUI macro plugin is missing from the Command Line Tools installation. Compile bundled Metal source at runtime so full Xcode's offline Metal compiler is not required.

## Research gate

App implementation starts after the four sensor and animation research reports have been reviewed. The repository's first milestone contains scope only. Research conclusions will be summarized here before implementation.

## Product interaction

Working title: AirVeil. A menu-bar utility with a native settings window. Motion connects automatically at launch and after wake. First-run actions are calibrate while facing the screen, authorize screen capture, then enable the desktop effect. A clearly labeled local preview must work before screen recording is authorized. Settings include activation angle, full effect angle, blur strength, feather width, responsiveness, and invert direction. Pause and Quit remain accessible from the menu bar.

## Privacy model

Process head motion and captured desktop frames locally, in memory. No network service, cloud inference, analytics, stored screen recordings, or microphone capture is needed. Repository publishing uploads source and synthetic test artifacts only. A software overlay obscures the same pixels for all viewers, including the owner; it is not a physical viewing-angle filter.

## Source independence

Review macTilt as a visual and architectural reference. Write original application and shader code rather than copying repository source without a confirmed license.

## Component contract for implementation

- `MotionService`: observable status, calibrated signed yaw in degrees (positive = physical left, verified or invertible), sample cadence/freshness, availability, authorization, source bud, explicit `start`, `stop`, and `calibrate`. Only fresh valid calibrated samples may drive tracking. Drop callbacks from previous runs. Clear calibration after discontinuity or reconnect.
- `VeilMath`: pure transfer and timing functions for bounded opposite-side coverage, threshold ordering, finite-input handling, and frame-independent response. Define rendering values as independent `left` and `right` strengths in 0...1. A positive calibrated left turn drives `right`.
- `DesktopOverlayController`: owns per-display capture sessions, windows, and renderers. Exposes async start, immediate stop/hide, status, and update with left/right strengths and visual settings. Own application excluded from captures; no audio/cursor capture. Strong failure state must never continue reporting normal tracking.
- `AppModel`: main-actor coordinator for mode (paused, preview, tracking), persisted settings, calibration workflow, capture consent, session events, menu state, and emergency pause. On a stale motion stream while active, retain an explicit full-screen cover until the user pauses or recalibrates, with menu-bar controls still reachable.
- `SettingsView`: native SwiftUI controls, live orientation display, clearly labeled simulated preview that does not claim sensor availability, actual error text, and calibration guidance. Preview visuals use synthetic content and require no screen permission.

Animation constants remain provisional until the fourth research report arrives. All desktop frames stay memory-only; diagnostic artifacts use synthetic content.

## Review of the first three reports

Apple's [WWDC23 Core Motion session](https://developer.apple.com/videos/play/wwdc2023/10179/) and installed macOS 26.5 headers establish native macOS 14 headphone motion. Implement explicit reference-attitude calibration; preserve the baseline while the head remains turned. Connection, source-bud changes, stale callbacks, and audio-induced discontinuities must invalidate confident tracking rather than silently recenter. Actual AirPods cadence and direction remain physical test requirements.

Apple's [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) establishes a live application-excluding display stream. Retain the newest valid image across idle callbacks; do not mistake a static desktop for lost capture. The renderer must return zero alpha outside coverage. Opaque blurred pixels prevent the sharp desktop underneath from leaking through; the feather is intentionally a transition zone.

The two research reports use different proposed yaw sign conventions. Resolve that here: **AirVeil uses positive yaw for a physical LEFT turn, negative for RIGHT.** Hardware verification must establish the sensor adapter's sign, while the renderer accepts independent nonnegative left and right strengths. A user-visible invert setting provides correction without changing the internal convention.

Use an original MPS Gaussian blur pipeline instead of copying macTilt's shader. Keep live desktop pixels flat and aligned. Only the obscuring amount and edge animate; the desktop does not need to fold or distort to achieve the requested behavior. A dark opaque cover remains available as a stronger obscuration style.

Following wearer feedback, unexpected loss of calibrated motion automatically pauses the active effect and clears the screen. Fresh motion plus an explicit Set center can resume it; a manual Pause cancels that recovery intent. Capture failures also clear automatically. This deliberately favors a usable desktop over holding a permanent failure cover. Place overlays below status-menu controls and keep the settings window above them. Register a global pause shortcut through the public Carbon hotkey API, without an Accessibility permission dependency. On sleep/session resignation, hide overlays and discard captured frames; waking resumes sensor detection automatically and requires deliberate recalibration/re-enabling of the desktop effect.

## Research gate completed

All four research assignments were reviewed before application implementation began. The animation report selects independent left/right exponential responses and a cached MPS Gaussian level bank with variance interpolation. This produces continuous variable softness without temporal accumulation. Provisional defaults are onset 8 degrees, full effect 32 degrees, attack 70 ms, release 140 ms, feather 12% of display width. The positive-left convention above is authoritative.

Render the synthetic preview through the same Metal compositor as the live desktop. Expose a clearly labeled simulation slider; synthetic preview is not sensor verification. Add opaque concealment and reduced-transparency support. Test alpha-zero neutral, alpha-one covered edges, source independence in opaque mode, mirrored masks, and finite/timing behavior before live acceptance.

## Stable signing and full-display sweep

Use a persistent self-signed certificate in a dedicated local keychain for development builds. Keep the default designated requirement bound to `com.shivhax.airveil` and the signing certificate; fail if that identity is absent. Never use an identifier-only requirement or fall back to ad hoc signing. Apple describes self-signed identities and stable designated requirements in [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) and [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html). No globally trusted root is needed in the verified local signing workflow. Certificate-chain lookup required temporary inclusion of the keychain in the existing user search list; the helper restores that list and locks the keychain after signing.

Capture preflight is advisory, while an actual ScreenCaptureKit request determines access. Report authorization denial separately from rendering or display failures so those failures do not tell the user to grant permission again.

Keep the same signed left/right transfer values in half and whole-screen modes. Half mode scales a fixed opposite-half mask. Whole-screen mode moves a feathered boundary from the opposite edge across the entire display. Independent left/right masks combine by alpha union during reversals, with exact clear and full-cover endpoints. The shader is shared by preview and desktop overlays.

## Motion acquisition and startup cancellation

Acquire headphone samples on a serial background operation queue. Timestamp and validate continuity there, then hand the newest pose to the main actor through a one-slot buffer. Preserve intervening source, timing, and quaternion discontinuities even when intermediate poses are coalesced. UI queue delays must not be mistaken for acquisition delays. Calibration remains an explicit user action; discarding obsolete UI deliveries must never silently establish a new head reference.

Before a queued capture or access-check task begins, verify its generation still matches the user's current intent. Recheck capture generation, failure state, and the display ID/frame/backing-scale snapshot across each asynchronous startup boundary. Pause or a changing display arrangement must not let obsolete startup work publish an active effect.

## Selected displays and pointer interception

Enumerate connected displays locally and persist selections by display UUID. A deliberate selection change pauses capture; an empty selection cannot enable. Build capture only for selected current IDs and retain startup topology revalidation.

Nonactivating AppKit panels intercept clicks and scrolling without keyboard focus or additional monitoring permission. The panels follow the compositor's blur mask above 5% coverage, or cover the selected display when the whole-display blocking option is chosen. Reserve the menu-bar area and keep AirVeil controls higher. Pause, failure recovery, selection changes, and shutdown remove blocker windows synchronously. Do not claim cancellation of a drag already dispatched before the blocker appeared.
