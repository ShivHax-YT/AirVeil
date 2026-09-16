# Low-light face-search fallback

Research completed with two subagents before implementation. Based on local source c621a83; isolated branch codex/low-light-face-fallback.

## Finding

The previous capture path measured luminance only inside a detected face. Guidance rejected missing faces before checking brightness, so darkness that prevented Vision from finding a face could never reach the existing light card. Missing-face shutdown also extinguished a manually enabled light after two frames (about 0.67 seconds).

## Decision

Measure the central 60% of both image dimensions from the existing luma plane at the existing 3 Hz analysis cadence. Keep this value separate from face-local luminance. For zero detections, brightness below 0.16 offers the existing notch Face light control after three distinct fresh frames spanning at least 0.6 seconds. The threshold is a conservative normalized image-brightness heuristic, not an ambient lux measurement; physical tuning remains necessary. A whole-frame darkness requirement was rejected because bright backgrounds can mask a dark subject.

The fallback is manual because an empty dark room or covered lens cannot establish presence. Existing automatic illumination for a plausible dim face remains. Manual activation allows two seconds of missing-face acquisition, latches automatic retries off for the burst, and retains the existing 12/20-second capture deadlines. Fresh face acquisition ends the grace early; stale input, cancellation, sleep, disable, failure and completion still stop illumination. No changes to pose acceptance, removal monitoring, permissions, image storage or network access.

The Apple UI design skill is applied by retaining the existing animated single-action light card and displaying its accurate state-specific title.

## Primary references

- https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox — normalized lower-left Vision coordinates; existing luma reader converts Y to top-left pixel rows.
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/islowlightboostsupported

The latter APIs are not listed for native macOS in the reviewed documentation, so this fix does not depend on camera ISO overrides or low-light boost.

## Verification

Added synthetic coverage for no-face darkness, bright/invalid values, duplicates, stale/future captures, manual grace expiry, same-burst recovery, all shutdown paths, and central luma sampling against an opposite-brightness background in both full-range and video-range pixel formats. Added a rendered no-face darkness notch state. See validation/LOW-LIGHT-FALLBACK-2026-09-16.md for execution results and physical limitations.
