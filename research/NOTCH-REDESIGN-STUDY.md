# Notch redesign: supplied recording study

The two supplied files were inspected as local reference footage, not as instructions embedded in media. Neither recording shows Activity Monitor or an AirVeil failure. The 23:31 file shows the Spotlight capsule; the 22:58 file shows an iPhone Dynamic Notch concept playing in a video player.

## Evidence and timing

- `Screen Recording 2026-09-13 at 10.58.16 PM.mov` (the actual filename uses a narrow no-break space before PM): 2940 × 1912, nominal 60 fps, 2.727 s. Extracted every frame into ignored `build/notch-study/ref-*.png`; reviewed 30 fps cropped contact sheets plus full-resolution source frames.
- `Screen Recording 2026-09-13 at 11.31.09 PM.mov`: 2940 × 1912, nominal 60 fps, 3.830 s. Reviewed at 8 fps and inspected the capsule morph interval.
- The attached smile still and four-panel drawing define the requested Mac arrangement; the current rail still establishes that the curved head-direction ticks must remain.

| Reference interval | Visible behavior | Implementation target |
| --- | --- | --- |
| 22:58 clip, 0.000–0.167 s | Hardware notch stays compact; no floating detached card. | The starting silhouette is the physical cutout. |
| 0.183–0.450 s | The bottom edge descends, initially quickly, then settles; bottom corners stay rounded. The notch width is essentially constant after accounting for the phone camera move. | A roughly 0.46 s eased shape expansion anchored to the display top. Content is clipped into the growing black shape, rather than vertically squashed. |
| 0.450–1.050 s | A small face glyph fades in below the camera hardware, centered within the extension. | A centered live camera circle and the existing curved motion rail; controls are disclosed separately. |
| 1.067–1.183 s | The neutral face outline turns green and rounds into a circle; facial marks fade. | Green outline starts the success morph only after accepted calibration evidence. |
| 1.183–1.633 s | Interlaced rotating elliptical loops occupy the same circle; no spinner text or check mark. | Short deterministic loop animation in the success glyph. |
| 1.650–1.767 s | Loops converge to a circular outline; the eyes, bent nose, and smile appear. | Custom stroked smile geometry, not an unrelated SF Symbol. |
| 1.767–2.250 s | The smile holds clearly. | Final smile holds before dismissal. |
| 2.283–2.483 s | Face fades while bottom edge retracts toward the notch; original phone UI remains beneath. | Reverse shape reveal, retaining focus and input passthrough outside the actual silhouette. |
| 23:31 clip, about 1.2–1.5 s | Spotlight capsule shortens and four round actions separate with soft settling. | Similar restrained easing for progressively disclosed actions; not a literal reproduction of Spotlight controls. |

## Geometry interpretation

The video contains a moving, perspective-rendered phone, so its screen-pixel rectangle cannot be copied directly to a Mac. The invariant is the attached black silhouette, nearly notch-width extension, large rounded lower corners, and a centered glyph. The user's four-panel drawing specifies a taller camera/rail state and shorter smile state. The implementation therefore takes width from the actual Mac cutout plus a modest shoulder, keeps the top safe region exactly hardware-width, and grows beneath it. On a display without a cutout it falls back to a rounded floating surface below the menu bar.

The smile still has a circular outline about 6% of the circle diameter in thickness, short vertical eyes around 30% and 70% of the width, a bent nose on the centerline, and a shallow curved mouth. Those proportions are encoded as normalized vector paths so Retina output stays sharp.

## Fidelity and verification boundaries

The app follows the supplied silhouette, sequence, approximate timings, and custom smile proportions. It does not reproduce the source video's artificial phone movement, reflective glass sweep, or blurred phone wallpaper: those are part of the filmed concept scene, not the requested Mac UI. Real camera and AirPods feedback are used only during a real check; deterministic fixture motion is explicitly confined to animation previews and rendering tests. Success decoration never makes the calibration decision.

Generated sheets and native renders stay in ignored `build/`, not Git. Native UI checks cover attachment geometry, menu-bar exclusion, transparent-corner hit testing, nonactivating focus, cancellation and session transitions. Manual perception of timing and the physical wearer checks remain separate from synthetic rendering.

## Implemented native verification

`bash scripts/test-notch-ui.sh` uses the installed 26.5 SDK (the current default 27 SDK requires an unavailable SwiftUI macro plugin in this CLI toolchain). It verifies 18 screen-geometry assertions and 35 native controller/lifecycle assertions, then renders 22 Retina fixtures without actual camera capture. The fixtures include six expansion-mask steps and six success-glyph steps. The camera, light card, smile, orbit transition and transparent rounded silhouette were inspected visually on a neutral gray backdrop. A dedicated dismissal regression retains the accepted smile during retraction and prevents an older delayed close from hiding a newer check. These render fixtures verify shape and sequence, not a measured live frame-rate guarantee.
