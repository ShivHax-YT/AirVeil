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
