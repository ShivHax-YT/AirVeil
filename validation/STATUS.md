# AirVeil validation status

## Verified

- Four cited research reports completed and reviewed before app implementation.
- Native macOS app builds against macOS 26.5 SDK with deployment target 14.0.
- App installed at `/Applications/AirVeil.app`, signature verified, and launched.
- 2,088 deterministic synthetic motion/math assertions pass.
- Actual GPU render tests pass at 1x and 2x for transparent neutral pixels, opposite-side masks, monotonic/mirrored feather, premultiplied alpha, opaque source independence, full shield, and top-left image orientation.
- Running native settings window inspected visually; simulated left turn produces right-side blur with a clear left side.
- Independent reviews found and fixed run-loop freshness, terminal retry, buffered-sample lag, display-change reveal, preview failure-state, and shortcut-advertising issues.
- Private GitHub repository created using GitHub Desktop and research milestones pushed.

## Pending live acceptance

AirPods Pro 3 physical direction, sample cadence, calibration stability, live desktop capture, full-screen/Spaces coverage, display changes, permission recovery, reconnects, and sustained performance require live testing. Bluetooth model availability is not a successful head-motion test. Hardware was reported disconnected at the initial setup check.

The oldest startup sample's absolute acquisition age remains unverified because headphone timestamp-to-host epoch was not assumed. Increasing delivery lag is detected relative to the best observed offset within a source session.

No iPhone/iPad system-wide version is claimed. No confidentiality guarantee is claimed for blur.
