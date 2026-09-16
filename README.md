# AirVeil

### Look away. Keep your screen private.

AirVeil is a native macOS privacy app that uses AirPods head tracking to obscure the side of the desktop behind you. Turn left and the right side is covered; turn right and the left side is covered. The rest of the screen stays clear.

**[Download AirVeil 0.16.1 for Apple silicon](https://github.com/ShivHax-YT/AirVeil/releases/download/v0.16.1/AirVeil-0.16.1-apple-silicon.dmg)** · [Release notes](release-notes-0.16.1.md)

## Highlights

- **Directional privacy** — choose an opposite-half blur or a whole-screen sweep.
- **AirPods head tracking** — set independent left and right start angles and response speed.
- **Notch controls** — center tracking, enable or pause blur, and open Settings without leaving your current app.
- **Optional camera alignment** — briefly confirm that you are facing forward; images are processed locally in memory.
- **Presence actions** — optionally dim the built-in display while you remain seated or turn it off after you leave.
- **Interaction blocking** — prevent clicks and scrolling through covered areas.
- **Multiple displays** — choose which connected screens AirVeil protects.
- **Energy controls** — switch between Automatic, Smoothest, and Reduced energy capture.

## Requirements

- macOS 14 or later on an Apple silicon Mac
- Headphones that expose motion data through Apple Core Motion
- **Motion & Fitness** permission for head tracking
- **Screen Recording** permission for desktop blur
- Optional **Camera** permission for alignment and presence features

AirVeil does not request Bluetooth or microphone access.

### Compatible headphones

AirVeil is designed and tested for AirPods with dynamic head tracking:

- AirPods Pro (1st, 2nd, and 3rd generation)
- AirPods Max (Lightning and USB-C models)
- AirPods (3rd, 4th, and 5th generation)

[Apple also documents head-tracking support](https://support.apple.com/102596) for **Beats Fit Pro, Beats Studio Pro, Beats Solo 4, Powerbeats Pro 2, and Powerbeats Fit**. AirVeil checks [Core Motion availability](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/isdevicemotionavailable) at runtime, so these Beats models may work, but they have not yet been tested or guaranteed by this project.

## Install

1. Download and open the latest `.dmg`.
2. Drag **AirVeil** into **Applications**.
3. Launch AirVeil and follow the permission setup and guided tour.
4. Wear your AirPods, face forward, choose **Set center**, then select **Enable blur**.

AirVeil 0.16.1 is development-signed, not Apple-notarized, so macOS may block the first launch on another Mac. The repository is currently private, so repository access is required to use the links above.

## Everyday controls

Use the menu bar, Dock, Settings, or notch controls to enable and pause AirVeil. **Pause & Clear Screen** immediately removes every overlay. The global shortcut is **Control–Option–Command–P**.

Settings is organized into five tabs:

| Tab | What it controls |
|---|---|
| **Preview** | Simulated turns and current tracking status |
| **Tracking** | Centering, camera assistance, Face light, and direction refresh |
| **Displays** | Protected screens and click/scroll blocking |
| **Appearance** | Coverage, start angles, blur, feathering, and response |
| **Power** | Presence actions, brightness target, and energy use |

## Privacy

Motion, desktop frames, and optional camera images are processed locally. AirVeil has no analytics, advertising, cloud inference, or network service, and it does not save camera, desktop, or audio recordings.

AirVeil is a software privacy aid, not an optical privacy filter. It cannot guarantee that all content is unreadable, and secure macOS surfaces or every fullscreen app may not be covered. Presence sensing is not identity verification. See the bundled [Privacy Policy](Resources/Legal/PRIVACY.md), [Terms of Use](Resources/Legal/TERMS.md), and [Cookies & Local Storage](Resources/Legal/COOKIES.md).

## Build from source

Install Xcode Command Line Tools, then run:

```sh
python3 scripts/setup-signing.py  # once per Mac
./scripts/install.sh
```

This builds, locally signs, installs, and opens `/Applications/AirVeil.app`. The signing identity is stored outside the repository so macOS permissions remain stable across local updates.

Other useful commands:

```sh
./scripts/build.sh                # build without installing
./scripts/build.sh --development  # include developer previews
bash scripts/package-dmg.sh       # create a DMG and checksum
./scripts/test.sh                 # run automated tests
./scripts/test.sh --performance   # include the GPU benchmark
```

Build and test results verify software behavior, not physical AirPods accuracy, trackpad feel, battery savings, or every lighting and display setup. Current evidence and remaining hardware checks are recorded in [validation/STATUS.md](validation/STATUS.md).

## Technology

Swift, SwiftUI, AppKit, Core Motion, AVFoundation, Vision, ScreenCaptureKit, Metal, and Metal Performance Shaders.
