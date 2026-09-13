# AirVeil architecture decisions

## Platform

Use native Swift, AppKit, SwiftUI, Core Motion, ScreenCaptureKit, and Metal. This avoids a browser-to-native motion bridge and uses public macOS APIs. The initial deployment target is macOS 14.0. On this development Mac use the installed macOS 26.5 SDK explicitly; the default SDK's SwiftUI macro plugin is missing from the Command Line Tools installation. Compile bundled Metal source at runtime so full Xcode's offline Metal compiler is not required.

## Research gate

App implementation starts after the four sensor and animation research reports have been reviewed. The repository's first milestone contains scope only. Research conclusions will be summarized here before implementation.

## Product interaction

Working title: AirVeil. A menu-bar utility with a native settings window. First-run actions are connect motion, calibrate while facing the screen, authorize screen capture, then enable the desktop effect. A clearly labeled local preview must work before screen recording is authorized. Settings include activation angle, full effect angle, blur strength, feather width, responsiveness, and invert direction. Pause and Quit remain accessible from the menu bar.

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
