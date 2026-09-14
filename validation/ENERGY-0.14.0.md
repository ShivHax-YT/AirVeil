# Energy-aware capture validation — 0.14.0 build 18

September 14, 2026. Changes researched first, implemented by a dedicated coder, independently reviewed, and integrated on `codex/energy-aware-operation`.

## Behavior

Automatic requests up to 60 desktop frames per second normally, or 30 while Low Power Mode is enabled or thermal state is serious/critical. Smoothest requests 60; Reduced energy requests 30. These are capture delivery limits, not guaranteed rendered frame rates or measured energy savings. Selection persists; power/thermal notifications and wake refresh the policy. Per-display asynchronous updates are serialized and converge to the newest request. Failed optional updates keep the last functioning capture and show a separate status. Stopped sessions reject late callbacks.

The only AppModel integration is policy delivery, wake refresh, reset, and teardown. No motion service, camera service/coordinator, removal policy, presence, brightness, input geometry, Metal renderer, or notch production source changed. Capture configuration tests verify all explicitly configured non-cadence fields remain identical. No new permission or network service was added.

## Verified

- `bash scripts/test.sh`: passed all policy, lifecycle, tracking, camera, presence, brightness, removal, display, pointer geometry, and actual Metal rendering suites. Includes 267 AppModel lifecycle assertions and 40 display/configuration checks.
- New production-policy tests: full mode/thermal/power matrix, initial read, invalid saved values, persistence/reset, background notifications, explicit refresh, duplicate suppression, and observer shutdown.
- New production-cadence tests: rapid changes, serialized reconciliation, failure retention/no retry loop, stopped and replacement sessions, invalid requests, and independent displays.
- `bash scripts/test-notch-ui.sh`: passed 18 geometry and 43 native lifecycle checks; rendered 27 notch states and two face-light frames.
- `bash scripts/test-settings-tour-ui.sh`: generated 60 native tour renders and eight energy-control renders without starting sensors or desktop capture. New energy card inspected in light/dark appearances. The locked/offscreen tour rendering did not establish scrolling to the target; live verification remains pending.
- `git diff --check`: passed.
- Signed macOS 14-target Apple silicon build and compressed DMG verification passed. Read-only mount verified app, Applications link, install notes, version/build, strict signature, and executable equality with the signed build; volume detached.

DMG SHA-256: `113c06acc9427f151f2a5143292a2214844c96b9d9237263ef6ebb5ba6c82ac4`.

Executable SHA-256: `9940d965dd9aac8a5bcb7b542fb47fa6517f96ca967777edebcc232774870f71`.

## Remaining acceptance

The Mac was locked during the native UI handoff. Installed picker/persistence and live tutorial spotlight verification, installation, and GitHub publication are pending unlock. No physical AirPods, camera, brightness, Low Power Mode toggle, thermal stress, or battery-runtime measurement was performed. Existing physical wearer acceptance remains separate from software regression evidence. This build remains development-signed and not Apple-notarized.
