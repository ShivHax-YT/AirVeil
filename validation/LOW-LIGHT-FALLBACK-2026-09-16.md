# Low-light fallback verification — build 32

- `bash scripts/test.sh`: PASS (full non-hardware suite, including 201 camera coordinator checks and 58 notch guidance checks).
- Targeted camera-service rerun after adding background-contrast fixtures: PASS, 67 checks. Fractional ROI boundaries can include a boundary row; the fixture verifies the dark/bright decision with tolerance rather than requiring mathematically pure black/white.
- `bash scripts/test-notch-ui.sh`: PASS (135 native notch lifecycle checks, geometry checks, 44 rendered states plus the new dark-no-face preview and other motion fixtures, light border geometry/rendering).
- Visually inspected `build/notch-previews/dark-no-face.png`: complete title, single power action, unclipped layout matching existing notch design.
- `bash scripts/build.sh`: PASS; strict code-signature verification passed.
- Installed build 32 at `/Applications/AirVeil.app`, preserving prior build 31 under this worktree's build directory. Installed and built executable SHA-256 both `db6c5d574c7ac8ec5f64232694f7106855b64fa2351c370b1f26bdea1744f5f0`.
- Computer Use confirmed installed app launched and its live notch showed `Hold at center` with camera/AirPods direction feedback. That observation is not a dark-no-face trigger test.
- `git diff --check`: PASS.

Physical limitation: the central brightness threshold and the amount of light delivered still require evaluation in the user's actual room. Synthetic inputs establish state transitions and shutdown behavior, not real low-light face-detection accuracy. No physical dark-room acceptance claim is made.

Research and rationale: `research/LOW-LIGHT-FALLBACK-2026-09-16.md`.
