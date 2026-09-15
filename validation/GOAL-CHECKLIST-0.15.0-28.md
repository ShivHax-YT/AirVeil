# AirVeil goal checklist — build 28 follow-up

15 September 2026. This checklist separates implemented behavior from installed and wearer-confirmed acceptance. Build 28 is installed and strictly verified. Automated and native UI checks pass; the new physical low-light/dismissal sequence is pending.

## Current goal

| Requirement | Evidence before build 28 | Remaining work |
|---|---|---|
| Restore original brightness after lock and sleep, in either AirPods return order | Four wearer-confirmed build 27 passes: both orders after manual lock and actual Apple-menu Sleep. One actual wake reading exceeded the previous ownership tolerance and still restored correctly. | Three automatic-departure cycles per return order under current low lighting; the four existing passes cover distinct cases, not three repeats each. |
| Organize Settings into clear tabs | Five tabs implemented and inspected. Native renders cover all tour targets at two sizes and appearances. | Complete installed tour interaction review, including minimum window size. |
| Sync head, moving arc marker, and degrees | Wearer confirmed all three follow real head movement in build 26. Stop sync preserves saved thresholds. | No new implementation requested. |
| Show wear reminder; Turn off feature restores brightness and stops cameras | Wearer confirmed both cleanup effects; automated cancellation and persistence checks pass. | Verify new dismiss control separately from Turn off feature; retain physical feature-off persistence/re-enable acceptance across relaunch. |
| Enable blur while AirPods are out, then align and start automatically on return | Full Settings route wearer-confirmed in build 25; notch route covered by native action/lifecycle checks. | Exercise the direct notch route on the installed app. |

## Latest requested additions

- [x] Low-light notice appears before brightness restoration, explains why, then transitions to a seat-check visual after success.
- [x] Restore owned brightness once without stopping seat monitoring or repeatedly dimming again in the same removal episode.
- [x] Fresh darkness cannot be mistaken for departure; valid empty-seat evidence may lock only when locking is enabled.
- [x] Independent Settings switches for dimming and locking; dimming defaults off, locking defaults on, with deliberate saved opt-outs respected.
- [x] Turning dimming off restores brightness while retaining lock monitoring when enabled; both switches off cancels removal actions.
- [x] Wear-reminder × dismisses the presentation only; returning AirPods still runs the normal camera alignment.
- [x] Run behavior and native UI checks, package and verify build 28, and inspect installed Power controls and tab labels.
- [ ] Wearer-confirmed low-light notice → restored brightness → continuous seat check, × dismissal, and automatic departure in current lighting.

## Earlier request limits

Dock and Command-Tab visibility and the live head/dial were accepted by the wearer. Native settings/window and tutorial fixes, glass/background/notch animation revisions, and app copy/legal reader work are recorded in earlier validation files. Individual left/right AirPod wear detection remains a platform/evidence limitation: a continuous stream from the other ear cannot reliably identify removal of the nonstreaming ear. The current removal workflow uses sustained motion loss after a stable wear session. These facts are not broadened into a claim that every original hardware scenario passes.

## Build 28 validation and installation

- Full regression passed in `build/build28-regression.log`: 374 AppModel lifecycle, 306 brightness, 142 removal coordinator, 75 presence geometry, and 34 presence-capture checks, plus existing motion, permissions, notch guidance, energy, input geometry, and real 1×/2× Metal render suites.
- Native notch checks passed: 18 geometry, 128 lifecycle, 35 rendered states, all-stage dismiss/Off visibility, and motion/Reduce Motion fixtures (`build/notch-lowlight-dismiss.log`). Fresh render files avoid a stale offscreen observation artifact; the final restored/monitoring images visibly include both controls.
- Settings passed 64 tour, 20 tab, and 8 energy renders (`build/build28-settings-tour-ui.log`). All tour targets remained visible and onset preferences stayed unchanged. Offscreen standalone tab-strip artifacts are not live UI evidence; the installed build's tab labels were inspected and render normally.
- All three bundled policies load, with six native reader renders (`build/build28-legal-ui.log`). Only feature descriptions changed to match the independent switches and removal behavior.
- The first regression exposed a real delayed-cleanup case: turning dim off could leave an unconfirmed restoration barrier without another event to retry it. The AppModel retry guard now handles that state. A second attempt caught a Swift 6 test-fixture closure error; the injected actor-isolated delay fixed it. Both attempts remain in `build/build28-regression-first.log` and `build/build28-regression-second.log`; the final suite passed.
- Installed `/Applications/AirVeil.app` through a normal quit and LaunchServices restart. Power shows **Lock when I leave: on** and **Dim while I stay seated: off**. The prior 23% target is preserved. No camera or brightness action was used to demonstrate these defaults.
- Physical low-light and dismissal acceptance is pending; no claim that dark camera frames can prove departure. The four build 27 brightness passes remain historical physical evidence, not a substitute for this new sequence.

The version is 0.15.0, build 28. `build/validation/release-0.15.0-build28.json` records DMG SHA-256 `26e5a45be7e39c69bc3c0317b24286dfd474b2fede99dfa1dbe39c418b2543ac` and executable SHA-256 `5e360fb23ac531325b792dfc52eab0c4ca593dbe2499c98ec16b8f07129175af`. Installed executable and policies match the signed package; strict signature verification passes and developer preview commands are excluded. The verified build 27 installer is archived locally. No public release or push was made.
