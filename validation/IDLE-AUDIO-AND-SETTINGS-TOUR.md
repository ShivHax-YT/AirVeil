# AirVeil 0.12.0 (build 16) — idle audio and Settings tour

## Behavior

- Core Motion disconnection remains a transport diagnostic. Only stable per-bud in-ear loss increments the removal-policy event count. Missing metadata and device handoff cannot request presence capture or display sleep.
- A motion gap still invalidates the sensor reference and clears blur; it never silently trusts a changed zero. Startup, confirmed ear return, or an explicit user action permit a camera attempt. An interrupted/failed attempt cannot retry on each new sensor epoch. Refresh direction or Enable blur lets the user retry.
- Previously observed worn evidence survives an unknown transport state so a late, confirmed ear-removal update can still start the full debounce delay.
- Camera assistance also monitors ear metadata when display removal is disabled, preserving confirmed-return recovery. With neither feature enabled the supplement stops.
- The first-launch Settings tour has 14 steps, spotlight cutouts over the actual controls, automatic scrolling, a subtle card entrance, Back/Continue/Skip, saved completion, and replay. It covers all Settings controls without changing effect preferences. Initial sensor startup waits for completion/dismissal; pending brightness restoration does not wait.

## Verified

- `bash scripts/test.sh` passed, including motion transport, wear evidence, camera coordinator, AppModel lifecycle, removal/debounce, presence/brightness restoration, and Metal rendering.
- Regression cases cover transport-only disconnect, twenty successive interrupted camera epochs, confirmed return rearming, late removal metadata, and startup tutorial sensor gating.
- Tour state tests passed: first launch, completion, skip, replay, bounds, stable target IDs, and preference isolation.
- `bash scripts/test-settings-tour-ui.sh` produced all 56 native renders (800x850 and 740x660, light/dark). All compact spotlight destinations were visually reviewed. The offscreen harness disables animations to settle scroll positions.
- Traversed all 14 steps in the live app. Visually inspected preview, tracking, camera, removal, onset dial, expanded fine tuning, and final controls. The live preview and dial are correctly composited; AppKit bitmap caching omits the Metal preview and misplaces the existing 3D dial head in offscreen images, so those images alone are not proof of those layers.
- The final development-signed app was installed at `/Applications/AirVeil.app`, retaining the previous installation under `build/AirVeil.before-idle-tour.*.app`. The installed executable exactly matches the packaged executable.
- DMG checksum and mounted app signature passed. Mounted contents are only AirVeil.app, an Applications link, and installation instructions. The image was ejected after inspection.
- The installed update was opened and left on the welcome tour via its replay control.

DMG SHA-256: `0782f897f46d43d254798bbd6628d3c17f62a64bb7890855309df96f0d1b5178`

## Remaining physical acceptance

These checks do not establish actual AirPods behavior during a phone handoff or music pause. The wearer should check music pause, idle without a phone, phone audio handoff, and removal/reinsertion of each bud. If the headset disconnects before providing a usable ear-state change, automatic removal waits rather than guessing. No real brightness, display-sleep, or camera test was performed for acceptance during this change. No GitHub release was published.
