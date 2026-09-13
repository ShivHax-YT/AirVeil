# AirVeil

AirVeil is a native macOS menu-bar app that uses AirPods head motion to progressively obscure the opposite side of your desktop. Turn left to blur the right side; turn right to blur the left. The untouched side stays fully transparent and interactive.

## Requirements

- macOS 14 or later and a Metal-capable Mac.
- AirPods with dynamic head tracking; AirPods Pro 3 are the initial hardware test target.
- Motion access for the sensor and Screen Recording access for the live desktop effect.
- Xcode Command Line Tools to build. Full Xcode's offline Metal compiler is not required.

## Build and run

```sh
# Once per Mac, before the first build:
python3 scripts/setup-signing.py
./scripts/install.sh
```

This builds an app for the current Mac's architecture, signs it with a persistent local development identity, installs it at `/Applications/AirVeil.app`, and opens settings. An existing AirVeil install is retained in the ignored build directory. The build script prefers the installed macOS 26.5 SDK to avoid a missing SwiftUI macro plugin in this Mac's default SDK; set `AIRVEIL_SDK` to use another complete SDK.

To build without installing, run `./scripts/build.sh`. Open `/Applications/AirVeil.app` to return to settings later.

## Setup

1. Connect and wear the AirPods on this Mac.
2. AirVeil detects connected, worn AirPods automatically. Allow Motion access when requested.
3. Face the center of the display and hold still briefly. Choose **Set center**.
4. Confirm in the preview that a physical left turn obscures the right side. Use **Invert direction** if needed.
5. Choose **Allow screen capture** and enable AirVeil in the macOS privacy settings. Reopen the app if macOS requests it. Subsequent builds use the same signing identity to preserve this approval.
6. Choose **Enable desktop effect**.

**Pause & Clear Screen** in the menu bar immediately removes all overlays. The app also registers **Control–Option–Command–P** as a global pause shortcut and reports when registration fails. Quitting removes the effect.

The preview slider uses a synthetic sample desktop and requires no screen capture. Its simulation is separate from live sensor verification.

## Stable permissions across updates

Builds reuse one certificate and private key in a dedicated keychain under `~/Library/Application Support/AirVeil/Signing`, outside this repository. The keychain password is a random value stored in that private directory for local build automation. Do not share this directory or delete it between builds. The build fails if its identity is missing; it never silently falls back to ad hoc signing. The signing helper temporarily includes this keychain in the user search list, restores the original list, and locks it afterward. It does not add a trusted root or change system trust settings.

Migrating from an older ad hoc build requires one new macOS screen-capture approval for the persistent identity. The app checks actual ScreenCaptureKit access; the preflight indicator alone no longer prevents capture. macOS still controls consent and may require it again after revocation, an identity replacement, or OS policy changes. This local certificate is for development on this Mac, not a notarized public release.

## Controls and behavior

- **Directional half / Whole-screen sweep** selects opposite-half blur or a moving blur edge across the full display. Turning left starts at the right edge and sweeps left; turning right mirrors it. At the full-effect angle, the entire display is blurred.
- **Reset defaults** restores all effect settings without changing permissions or calibration.
- Default onset: 8 degrees; full effect: 32 degrees.
- Adjustable blur, edge feather, and response time.
- **Opaque cover** removes source color at full strength for stronger obscuration.
- AirPods motion starts automatically at launch, reconnects automatically, and retries interruptions with a bounded delay.
- Calibration is deliberate; holding a turned pose never silently resets center.
- Sensor gaps, earbud source changes, and detected reference jumps invalidate calibration.
- Unexpected motion/capture failure while enabled shows an opaque cover. Pause remains available from the menu bar and the registered shortcut.
- Sleep or session resignation pauses the effect and discards captured frames. AirPods detection resumes automatically after wake; set center and enable to resume.
- Display reconfiguration requires rebuilding capture with a deliberate pause/re-enable.

## Privacy and platform limits

Motion and desktop frames are processed locally, in memory. The app captures no audio, runs no server, and includes no analytics or cloud inference. Its own windows are excluded from its capture streams to prevent repeated blur feedback. It does not save recordings.

Software blur changes the same pixels for everyone looking at the display. It is not an optical privacy filter, cannot detect bystanders, and does not guarantee unreadability of all content. Transition edges are partly visible. Secure macOS surfaces and every fullscreen application are not guaranteed to be covered.

iPhone and iPad support headphone motion, but a normal app cannot reproduce this arbitrary system-wide overlay across other apps. A future mobile implementation would need an explicitly limited app-owned content surface. The implemented target is macOS.

## Research and validation

Four research reports precede implementation:

- [Sensor API](research/01-sensor-api.md)
- [Sensor feasibility and calibration](research/02-sensor-feasibility.md)
- [Desktop capture and overlays](research/03-desktop-overlay.md)
- [Blur and animation](research/04-blur-animation.md)

[Architecture decisions](research/DECISIONS.md) and [acceptance plan](research/VALIDATION-PLAN.md) distinguish documentation, synthetic tests, and physical evidence.

Run `./scripts/test.sh --performance` to include the synthetic native-resolution GPU benchmark. Run `./scripts/test.sh` for deterministic motion math, motion-delivery and app-lifecycle regressions, and actual Metal GPU render tests. Synthetic PNGs are written under `.build/render-artifacts/`. Passing these checks does not establish physical AirPods direction, sustained drift behavior, or privacy effectiveness. See [validation status](validation/STATUS.md) for current evidence.

## Implementation

Swift / SwiftUI / AppKit, Core Motion, ScreenCaptureKit, Metal, and Metal Performance Shaders. Original code informed by public Apple documentation and the visual behavior of [macTilt](https://github.com/lqSky7/iphone-duo-macos-animation); no macTilt source is copied.
