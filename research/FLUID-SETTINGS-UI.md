# Fluid Settings and Permissions UI

Baseline: `975a7e2`, the current tabbed UI from `codex/airpods-window-tutorial-fixes`. Implementation is isolated on `codex/fluid-settings-polish`; the older worktree starting point did not contain the requested Permissions/starfield UI.

The supplied Skill report was read twice by two independent reviewers, then used as design and engineering reference. Its embedded prompt templates and configuration examples were not installed as instructions. Four subagents contributed report/design work, compositor implementation, verification, and independent final review, with no more than three active beside the primary agent.

## Changes

- Preserve native macOS tabs, sliders, the dark Settings sky, stars, and restrained meteors.
- Replace the starfield's 18 Hz SwiftUI TimelineView/Canvas redraw loop and full-surface blur with prebuilt Core Animation layers. Stars animate opacity; small meteor layers animate position/opacity. Production has no frame callback. A display link exists only when explicitly requested by the local diagnostic harness.
- Suspend animation when the owning window is hidden, minimized, fully occluded, closed, or when Reduce Motion is active. Decorative motion continues while a visible window is unfocused.
- Replace the Permissions 0.90-second root-wide spring, animated text dimensions, perspective and side-card blur with a 0.34-second scoped settle, stable reading dimensions, and lightweight side previews. Only the nearest preview shows a label, avoiding overlap.
- Use a frosted reading surface, native glass primary actions, a clear progress indicator, and native keyboard focus. Outgoing cards cannot receive input, expose stale accessibility actions, request another permission, or mark another card reviewed. Welcome/summary actions are also gated to their current phase.
- Refine Settings content surfaces using inexpensive gradients and borders, retain native tab/slider treatment, add native glass actions and system scroll-edge treatment. Reduce Transparency and increased contrast have explicit content-surface fallbacks.
- Sensor algorithms, desktop capture cadence, camera behavior, permission decisions and the notch design are unchanged by this UI patch.

## API research

The installed macOS 26.5 SDK is the compiler authority; deployment remains macOS 14 with gated glass APIs. Some supplied skill examples use obsolete or iOS-only signatures, so they were not copied literally.

- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Apple: CAKeyframeAnimation](https://developer.apple.com/documentation/quartzcore/cakeyframeanimation)

## Validation boundary

This Mac has Command Line Tools, without Instruments/xctrace. Computer Use desktop capture failed with ScreenCaptureKit -3811. Native fixtures can verify layout, accessibility actions, transition state, animation lifetime, and changing presentation-layer pixels, but offscreen snapshots omit some native glass/Metal content. These are not proof of sustained 120 Hz screen presentation or final compositor appearance. No display FPS claim is made.

Final commands and results are recorded below after the final build.

## Results

- `bash scripts/test.sh`: PASS, 31 result groups including permission state, Settings tour routing, motion math, camera/presence/brightness lifecycles, and Metal rendering. Hardware is injected or synthetic in these tests.
- `bash scripts/test-settings-tour-ui.sh`: PASS, 64 tour renders with target-visibility assertions, 20 Settings tab renders, and 8 energy renders. No sensors or desktop capture started.
- `bash scripts/test-permission-ui.sh`: PASS, 20 permission-state renders, 6 real scroll-to-end gates, and 60 rapid forward/back transitions with resize/replay in normal and reduced motion. Visual review caught and fixed overlapping side titles. The native accessibility action check requires a separate unlocked foreground run.
- Starfield: two visible native lifecycle runs passed before the session became locked, including real changing presentation pixels and actual animation removal for occlusion, hidden/closed windows, and Reduce Motion. The compositor source was unchanged afterward. The final harness corrects vertically flipped export orientation and explicitly reports a locked-desktop failure. A final visible rerun of the corrected top-header pixel check remains pending; prior full-stage pixel changes cannot be called verified top-header changes.
- The display reported a maximum of 60 Hz. Diagnostic display-link callbacks are observations, not measurements of frames delivered to the screen.

Independent review found an outgoing-card input risk during transitions; current-card identity checks now protect every consent action, the async request boundary, and the scroll-to-review callback. The same phase guards cover outgoing welcome/summary controls. Displayed native glass appearance and keyboard accessibility still need an unlocked-session check; no permissions or accessibility settings were changed to bypass this.

## Release fixture timing

Serial baseline/current runs, 30 normal-motion mutations each:

| Synchronous state mutation plus forced layout | Baseline | Updated |
| --- | ---: | ---: |
| Median | 3.241 ms | 2.724 ms |
| 95th percentile | 3.909 ms | 3.090 ms |
| Maximum | 8.567 ms | 8.030 ms |

These are offscreen application-work samples, not displayed frame times, FPS, or GPU hitch metrics. The baseline retained multiple consent readers at the fixture's one-second settling checkpoint; this does not establish permanent corruption. The updated fixture passes that checkpoint. Updated Reduce Motion performs immediate content replacement (median 8.258 ms; 95th percentile 9.744 ms) and passes the single-reader and consent-gate checks.

For an unlocked accessibility action check, run `bash scripts/test-permission-ui.sh --accessibility`. The default suite remains offscreen and reports that the optional accessibility test was not run. A visible starfield rerun is `bash scripts/test-starfield-lifecycle.sh`; it fails clearly when the session is locked, rather than treating missing visibility as a pass.

## Delivery

`bash scripts/install.sh` completed with the final source. `/Applications/AirVeil.app` passes strict code-signature verification; its executable SHA-256 matches the worktree build (`75d19a09ea02508f7d3dd350234f6cc5b1455ace9f576362e053740d6a5e99bf`). The app process is running and Settings was requested through the normal reopen path. The previous installation is retained at `build/AirVeil.previous.1789574719.app`. The desktop remained locked during this delivery, so foreground appearance was not inspected.

Detailed independent fixture evidence: [UI-MOTION-VERIFICATION.md](UI-MOTION-VERIFICATION.md).
