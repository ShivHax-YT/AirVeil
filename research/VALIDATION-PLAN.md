# AirVeil validation plan

The macOS deliverable must satisfy the following checks before completion can be claimed.

| Requirement | Evidence required |
|---|---|
| Four research assignments before app implementation | Two sensor reports and two rendering/animation reports, all cited and reviewed |
| Native headphone input | Build against public Core Motion API and observe live connected AirPods Pro 3 callbacks |
| Remember original center | Original screen-facing reference changes only through Set center; removal/stale input does not replace it; rewear while turned remains a turn and returning to original forward posture returns near zero; detected reference invalidation pauses instead of silently choosing a new zero |
| Look left obscures right; look right obscures left | Physical turn test following neutral calibration, plus deterministic mapping tests |
| Smooth angle-dependent blur | Rendered intermediate frames, transition tests, sustained runtime observation |
| Live desktop and pointer policy | Capture changes reflected while covered; clear side transparent; new clicks/scrolls blocked in blurred regions or entire selected display as configured; controls remain available |
| Display selection | Connected count and refresh work; selected displays alone receive effect; persisted selection survives runtime display-ID changes |
| No recursive capture | Own application excluded from ScreenCaptureKit filter; live visual check |
| Disconnect and stale input | Deterministic lifecycle tests plus unplug/reconnect hardware validation; interrupted effect automatically pauses/clears, and explicit center resumes without a persistent black cover |
| Optional display off after removal | Actual delegate disconnect after fresh motion triggers once after delay; brief reconnect cancels; stale/reference changes never trigger; all displays turn off; normal wake works without an immediate repeat; password behavior follows Mac settings |
| Permissions | Clear denied/missing UI; successful capture only with user-granted permission |
| Display changes | Attached-display lifecycle and overlay frame mapping checked |
| Pause/quit | Overlay and capture fully stop; obvious controls available |
| Native polished controls | Inspect rendered settings panel and preview with real app running |
| GitHub milestones | Private remote exists; checked milestones committed and pushed |
| Reproducible install | Clean build, signed app bundle, launch and process verification |
| iOS/iPadOS scope | Document public platform capabilities and system-wide overlay restrictions |

## Physical test sequence

1. Connect and wear AirPods Pro 3, open AirVeil, and grant requested motion permission.
2. Confirm fresh samples, face the Mac, and Set center once; record this as the original forward posture.
3. Turn left slowly, hold, return to center, turn right, hold, and return.
4. Compare covered side, magnitude, latency, and whether small motion causes jitter.
5. Click and scroll in another application while one side is covered; verify interception in the configured area and normal interaction in clear/exempt areas.
6. Remove a bud, disconnect/reconnect, sleep/wake, and change audio spatialization modes.
7. Confirm pause and quit immediately clear all overlays.
8. Enable **Turn off displays when AirPods are removed**, with Automatic Ear Detection on. After live motion arms it, remove both buds. Confirm all displays turn off, wake normally, and confirm no repeated sleep while buds remain absent. Reinsert to rearm; a brief remove/reinsert must cancel the delayed request. Verify password behavior separately if Require password is set to Immediately.
9. With blur enabled, remove both AirPods and reinsert while looking distinctly left; wake if needed. Confirm the saved center is not overwritten and the turn remains nonzero. Return to the original forward posture and confirm near zero. Repeat right and with the other source-earbud order. Repeat after a manual Pause and confirm blur stays paused. Hold a turn during a continuous session and confirm the center does not shift.

A preview or synthetic sensor test does not prove AirPods Pro 3 hardware integration. A build passing does not prove visual privacy. Software obscuring changes the display for all observers.

## 2026-09-13 amendment: failed retained zero and current acceptance gates

This amendment supersedes the retained-reference expectation in the table and step 9 above. The wearer confirmed that the AirPods-only retained reference gave the wrong zero after removal/reinsertion while looking left or right. Saving the same numeric reference was insufficient. Do not repeat that claim as an achieved result or use it to enable blur after a gap.

In manual mode, any lost reference requires explicit Set center. Check that removal, stale input, source handoff, clock reset, and attitude discontinuity preserve diagnostic values without leaving the reference usable. Fresh steady samples must not silently choose a new center or resume from the invalid one. After an explicit center, previously active capture may resume only if the user has not canceled that intent and the Mac session is active.

### Optional camera acceptance

Camera assistance begins off by default. Until the user explicitly enables it, verify there is no camera input/session creation, permission prompt, or image acquisition. Use injected boundaries for automated tests; no test suite should activate a camera, sensor, screen-capture permission request, display-sleep command, or the user's real preferences.

The source implementation now has fixed built-in-camera bursts, a saved camera neutral/sign, and separate disposable sensor-epoch offsets. Full integration verification is in progress; camera physical correctness and timing remain unproved. Research reports are [camera APIs](CAMERA-ANCHOR-RESEARCH.md), [fusion design](HEADING-FUSION-DESIGN.md), and [energy](ENERGY-RESEARCH.md). Record final build/test and installation evidence separately in `validation/STATUS.md`.

After explicit camera opt-in, perform these physical checks before claiming original-direction recovery:

1. With the desktop effect paused, grant Camera access and keep the built-in camera fixed. Face the selected reference display and Set center; hold while it measures, make the prompted short left/right turn, and hold again. Verify the learned sign against physical turns. Setup must stop on completion or within 20 seconds.
2. Confirm the camera stops after alignment. Record only center revision, alignment revision, current heading, and aggregate timing/state diagnostics; do not save face images or motion histories.
3. Establish the original screen-facing direction, turn left, remove both AirPods, and reinsert while still turned. A successful check must report the actual nonzero turn. Return to the original direction and verify near-zero output. Repeat removing left and returning right, removing right and returning left, and with each source-earbud order. The saved camera center revision must stay unchanged while the disposable alignment changes.
4. Repeat held turns, brief rapid turns followed by a hold, modest head tilt, lighting changes, glasses, and ordinary seating movements. Measure angle error and recovery time. The prototype only admits modest yaw/pitch/roll, one large enough visible face, and stable windows; rejection is acceptable, silently replacing zero is not.
5. Test no face, multiple faces, large profile turns, blocked camera, denied/revoked permission, and camera contention. Verify a bounded recovery attempt of at most 12 seconds, no endless capture in one epoch, an honest waiting/error state, and a usable Refresh direction action. No invalid result may drive the effect.
6. Test Pause, disable, Quit, source/clock/reference changes, display-layout change, and sleep/session transitions before camera start, during analysis, and after an async callback is queued. Obsolete results cannot align a new epoch or enable capture. Wake requires a new valid camera alignment; explicit Pause cancels automatic resumption.
7. Change known camera framing or display geometry and verify rejection of the old setup. Move the physical setup without changing its ID to establish the documented detection limit; Set center must provide an explicit recovery route. Do not claim camera identity proves physical mounting continuity.
8. Only after heading checks pass while paused, enable the desktop effect and repeat off-axis rewear, original-center return, global pause, pointer blocking, removal-triggered display sleep, and normal wake. Camera recovery must not synthesize removal events or cause duplicate display-off actions.

Camera PTS conversion to host time does not prove that AirPods timestamps share that clock. Measure transport/processing delays and the consequences of timing mismatch; the engine's 200 ms guard plus stationary overlap is a prototype assumption. Include the actual 3 fps analysis cadence and processing delay in synthetic tests. Tests must reject old/future frames, unstable windows, source changes mid-burst, missing/nonfinite pose, and inconsistent sign calibration. A +35° return must remain +35°, and +179°/−179° wrapping must follow the short arc. Passing these mathematical tests does not establish Vision's physical angle accuracy.

### Energy and rendering acceptance

The implemented work isolates UI telemetry, suspends invisible previews, uses demand-driven rendering and a settling animation clock, and bypasses unused source/blur work for transparent or genuinely solid output. Desktop native resolution and the requested maximum 60 fps capture cadence are unchanged. No energy saving is measured yet; do not label the source change or a passing test as a battery-life result.

Automated checks must preserve the existing rendering and lifecycle suite and add:

- No full settings-model publication from high-frequency motion or smoothed strengths; unchanged rounded tracking values cause no small-snapshot publication either. Meaningful displayed changes still appear.
- Hidden settings receive no preview draws or presentation refreshes, while an enabled desktop effect continues to update. Showing settings restores the latest state and rendering.
- Fresh content, changed effect parameters, and resize each schedule necessary drawing. Settled static output does not require an always-running draw loop; GPU backpressure must not drop the final dirty redraw.
- Transparent/source-independent output skips source blits and Gaussian passes. Returning to visible blur consumes the latest available frame, with correct first-frame/readiness behavior and no stale content.
- Native-resolution neutral alpha, covered alpha, masks, reversals, intermediate opacity, reduced-transparency behavior, and pointer regions remain correct.

Measure before/after under the same display arrangement, power source, brightness, settings visibility, effect mode, and desktop workload. Compare paused hidden, paused visible, enabled neutral, held blur over static content, held blur over changing content, and moving edges over changing content; repeat one- and two-display cases. Record current Energy Impact, CPU, UI update counts, draw submissions, source/blur rebuild counts, and GPU duration over comparable settled intervals. Energy Impact is a relative score, not watts; its historical average is not an immediate after-change measure. Report observed limitations and visual regressions alongside any measured improvement. No installed-build or physical-success claim is made by this amendment.
