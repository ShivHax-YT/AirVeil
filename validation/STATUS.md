# AirVeil validation status

## Verified

- Four cited research reports completed and reviewed before app implementation.
- Native macOS app builds against macOS 26.5 SDK with deployment target 14.0.
- App installed at `/Applications/AirVeil.app`, signature verified, and launched.
- 2,094 deterministic synthetic motion/math assertions pass.
- Actual GPU render tests pass at 1x and 2x for transparent neutral pixels, opposite-side masks, monotonic/mirrored feather, premultiplied alpha, opaque source independence, full shield, and top-left image orientation.
- Running native settings window inspected visually; simulated left turn produces right-side blur with a clear left side.
- Independent reviews found and fixed run-loop freshness, terminal retry, buffered-sample lag, display-change reveal, preview failure-state, and shortcut-advertising issues.
- Private GitHub repository created using GitHub Desktop and research milestones pushed.

## Live evidence and remaining acceptance

The first integrated build received AirPods Pro 3 motion at approximately 49–52 samples/s from the left bud. The wearer confirmed that physical head motion blurred the in-app preview. The running app then reported successful live desktop capture and calibrated tracking. The Pause button was exercised and returned the capture status to paused. These are real runtime observations, separate from synthetic tests.

The newest build adds whole-screen coverage, reset defaults, clearer calibration, and idle rendering improvements. Whole-screen preview and reset to 8° onset / 32° full angle / 32 pt blur / 12% feather / 70 ms response were verified through the running UI. Paused static app CPU was observed near 1.1% after optimization, compared with a prior snapshot near 38%; these snapshots are not a controlled energy benchmark.

Synthetic native-resolution GPU benchmark at the main display's 1920×1080, 1x mode: 120 changed frames, last observed median 1.313 ms and p95 4.815 ms. This measures blit + three Gaussian passes + composition, not real display FPS or sensor latency. Eight repeated renderer release/reuse cycles pass; late frames are rejected. See Tests/PerformanceTests.swift to reproduce.

Final rebuilt-binary permission recovery and desktop behavior, explicit anatomical direction, sustained calibration, fullscreen/Spaces coverage, display reconfiguration, reconnect behavior, and manual global-shortcut confirmation remain pending. Rebuilds signed ad hoc may need fresh macOS permission approval. No final hardware-completion claim is made.

The oldest startup sample's absolute acquisition age remains unverified because headphone timestamp-to-host epoch was not assumed. Increasing delivery lag is detected relative to the best observed offset within a source session.

No iPhone/iPad system-wide version is claimed. No confidentiality guarantee is claimed for blur.
