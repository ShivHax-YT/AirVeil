# AirVeil 0.16.0 RC 1 — build 33

This release combines all three AirVeil worktrees: settings/window fixes, fluid glass and permissions UI, trackpad haptics, and low-light face-search recovery.

- Smoother settings starfield and meteor motion with visibility-aware rendering, refined native glass controls, and improved permissions transitions.
- Native trackpad feedback for buttons, toggles, selections, sliders, and the onset dial. Slider ticks are spaced and rate-limited; continuous values remain unchanged. Appearance → Trackpad feedback is enabled by default.
- Sustained darkness can offer the notch Face light button even before a face is detected. Manual lighting gives the camera two seconds to acquire a face without treating darkness as proof of presence.
- Includes the shared baseline's settings sizing, onboarding, brightness recovery, and notch flow fixes.

## Installation

Download `AirVeil-0.16.0-apple-silicon.dmg`, quit AirVeil, and drag the app into Applications. Requires Apple silicon and macOS 14 or later. The accompanying `.sha256` file verifies the download.

Development-signed, not Apple-notarized. This remains a release candidate: automated state/render tests do not establish physical AirPods behavior, dark-room accuracy, displayed frame rate, or trackpad feel on each Mac. Camera assistance is optional, and image processing stays local.
