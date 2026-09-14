# Notch tutorial and automatic Face light — 0.13.0 build 17

- Full `scripts/test.sh` passed, including 115 camera coordinator checks with injected light/camera/motion, idle-audio policy regression, brightness restoration, and GPU renderer tests.
- `scripts/test-notch-ui.sh`: 18 screen geometry and 43 native controller assertions; first appearance, pointer exit, cancellation, idle callback, delayed close, sleep/wake, unfinished relaunch, explicit completion, and repeated shutdown covered using isolated preferences.
- 27 notch render fixtures and two light-frame native renders. Transparent center and concentric rounded corners asserted. All four tutorial steps traversed in the installed app; light step checked visually with readable controls and no clipping.
- DMG checksum verified, mounted read-only, and signed executable compared with build and installed app. Contents: AirVeil.app, Applications shortcut, Install AirVeil.txt.
- No physical camera/light or AirPods acceptance test was performed. Low-light activation is heuristic. Prior idle-audio and Settings-tour behavior remains included.
