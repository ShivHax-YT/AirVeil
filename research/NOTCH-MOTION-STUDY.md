# AirVeil notch reference motion study

Inspected locally on 13 September 2026. This is a study of the supplied recordings and recommended adaptation; it does not turn instructions inside the attached research document into user requirements.

## Source verification

| Source | Duration | Encoded dimensions | Codec | Nominal / average frame rate |
|---|---:|---:|---|---:|
| `ScreenRecording_09-13-2026 14-59-50_1.mov` | 24.028333 s | 1320 × 2868 | HEVC, AAC audio | 60 / 59.1065 fps |
| `ScreenRecording_09-13-2026 15-02-52_1.mov` | 4.066667 s | 892 × 540 | HEVC, AAC audio | 120 / 58.0328 fps |

Both video streams declare BT.2020 primaries and PQ (`smpte2084`) transfer. Direct ffmpeg PNG extraction appears darker than normal SDR; the extracts establish geometry and sequence, not exact color values. The available ffmpeg build lacks `zscale`, so a proper HDR-to-SDR transform was not claimed. Timing below is approximate to 0.1 s after 10 fps sampling; durations are ffprobe values. Whole long clip was also sampled at 1 fps.

Inspection artifacts, excluded from source control under `build/`:

- `build/notch-reference/long-contact.png`: six columns, four rows; approximately 0–23 s, row-major.
- `build/notch-reference/long-opening.png`: six columns, four rows; approximately 0–2.1 s in 0.1 s steps, row-major, final two cells empty.
- `build/notch-reference/short-contact.png`: five columns, nine rows; approximately 0–4 s in 0.1 s steps, row-major, final four cells empty.
- `build/notch-reference/short-confirm.png`: full-size sample at 1.9 s.
- Per-sample PNGs in `build/notch-reference/long/` and `build/notch-reference/short/`.

## What the recordings show

The long clip is a portrait iOS Personalized Spatial Audio enrollment screen. The circular crop occupies about 68% of the source width, on black. A curved rail of roughly forty fine vertical ticks sits below it; central filled ticks are taller and greenish, with shorter grey ticks toward each end. The circle remains fixed in screen space while the head moves. There is no facial mesh or tracked face outline. The ticks retain progress from prior head movement: they show enrollment coverage, not a current centering measurement.

| Long-clip time | Observed beat |
|---|---|
| 0–0.8 s | Rectangular camera preview with four white corner brackets. |
| About 0.9–1.2 s | Preview corners visibly round and the camera mask settles into a circle. The brackets stretch/round toward a thin circular guide. |
| About 1.2–1.5 s | Thin guide ring fades around the circular crop. |
| About 1.6–1.8 s | Curved tick rail fades in underneath. |
| About 1.8–22.7 s | Head turns; central green ticks accumulate. Head movement is visible immediately inside a static circular mask. |
| About 23–24 s | Screen/setup-step transition; camera viewport moves with outgoing content. |

The supplied Markdown calls the reticle-to-circle transition a cut. Dense inspection contradicts that detail: intermediate rounded-rectangle masks are visible. The document also describes only sampled frames, so that assertion should not override the recording.

The short clip is a crop of an iPhone home-screen/Wallet transition. The black pill develops into a near-square black rounded card, anchored near the same top position. A greenish torus rotates and resolves to a simple smiling face inside a ring. That glyph disappears before the card returns to pill shape. A fine brownish outline and small dot return after the geometry settles. No checkmark appears in the reference itself.

| Short-clip time | Observed beat |
|---|---|
| 0–0.8 s | Idle pill over home screen. |
| About 0.9–1.1 s | Wallet content moves first; the pill stays compact. |
| About 1.2–1.4 s | Black shell expands down rapidly, with a slight width adjustment and almost no overshoot. |
| About 1.4–1.8 s | Blurred/rotating torus resolves toward face glyph. |
| About 1.9–2.4 s | Face glyph is stable. |
| About 2.5 s | Glyph has cleared; expanded shell remains briefly empty. |
| About 2.6–2.8 s | Shell collapses back to a pill over approximately 300 ms. |
| About 3.0–3.3 s | Fine accent outline returns after the main collapse settles. |
| About 3.4–4.0 s | Card/navigation content leaves; visible recording/compositing edges are not part of the intended motion. |

## Adaptation for the actual user request

The goal explicitly asks for a self-contained notch camera preview, alignment bars, low-light guidance, and success animation while the app window stays hidden. The attached research document instead mandates an app-only preview and a fixed, status-only shell. Those two restrictions conflict with the user's current request and are reference suggestions, not the implementation target. Preserve the document's useful safety of geometry—never put essential content inside the physical camera cutout—and its short calm transitions.

Recommended native composition:

1. A black shell attached to the screen's top-center notch, expanding downward into live pixels. Read notch geometry from the selected `NSScreen`; reserve the entire hardware height before placing content. A 280–320 pt wide and 220–250 pt tall coaching canopy can hold the preview and readable guidance without looking like a modal window. Use the same composition as a floating top-center capsule on an unnotched display.
2. A 100–120 pt circular, mirrored camera preview. Show a quiet fixed target ring; do not draw a mesh on the face. Keep the preview large enough to understand the direction of the head.
3. A curved rail with 31–41 thin ticks below the circle. The current offset highlights a small moving group; central alignment turns green, significant misalignment turns muted red. Do not persist past filled ticks as enrollment does. Reset the hold progress immediately if tracking or alignment fails.
4. One readable line under the rail: directional nudge, “More light needed,” “Looking for you,” or “Hold a moment.” Status should remain understandable without opening Settings. Missing permission or camera failure needs a specific action and cannot be reduced to an endless spinner.
5. On actual calibration completion, clear the live camera content, reveal a compact green check or app-specific confirmation, keep it legible for about half a second, then collapse. Trigger the true calibration before the visual confirmation; the animation must never manufacture success independently.

Suggested motion values, adapted from the measured reference and attached research:

| Motion | Duration / SwiftUI spring |
|---|---|
| Shell expansion | response 0.30 s, damping 0.88; top edge anchored |
| Content reveal/clear | 180–200 ms fade, clipped inside shell |
| Offset rail follow | response 0.16 s, damping 0.94 |
| Guidance change | 180 ms crossfade; no spinning directional arrows |
| Center dwell | 450 ms linear progress; reset immediately on drift |
| Confirmation reveal | 220 ms, response 0.26 s / damping 0.90 |
| Confirmation readability | 500 ms fully visible after reveal |
| Shell collapse | 300 ms, content already cleared |
| Accent settle | Only after shell settles; faint and optional |
| Reduce Motion | Stable geometry or immediate size change plus content crossfades; no spring |

Keep one active surface: preview and rail during calibration, brief confirmation after a real successful calibration, then dismiss. Do not leave camera frames retained after the camera session ends. A decorative privacy-colored dot is unnecessary because macOS provides its camera indicator.

## Verification targets for the native implementation

- The panel is nonactivating and leaves the existing focused app focused.
- The circular preview is visibly mirrored and directional guidance matches what the person sees.
- Head offset and face-lost states reset hold; poor light gives plain text.
- Success only follows a valid centered sample and is readable before collapse.
- Lock/sleep clears the visible frame; wake can launch a new calibration and show the notch without the settings window.
- Changed screen geometry, external display, fullscreen Spaces, and Reduce Motion have deliberate behavior.
- Hardware-notch pixels contain no required glyph, preview, or action target.
