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

Persistent permission across a changed signed build, live desktop capture, and the wearer-confirmed left/right whole-screen sweep now pass. Sustained calibration, fullscreen/Spaces coverage, display reconfiguration, physical reconnect/wake behavior, and manual global-shortcut confirmation remain pending. No broader hardware-completion claim is made.

The oldest startup sample's absolute acquisition age remains unverified because headphone timestamp-to-host epoch was not assumed. Increasing delivery lag is detected relative to the best observed offset within a source session.

No iPhone/iPad system-wide version is claimed. No confidentiality guarantee is claimed for blur.

## Persistent identity and automatic tracking update

The prior ad hoc builds changed identity on rebuild. AirVeil now uses a persistent, self-signed local development certificate in an isolated user keychain outside the repository. No global root trust was added. Strict signature validation passes, and the default designated requirement pins the bundle identifier and leaf certificate, rather than the executable hash. The keychain must temporarily be in the search list during signing; the helper restores the prior list and locks the signing keychain afterward.

Only AirVeil's stale ScreenCapture approval was reset with the supported `tccutil reset ScreenCapture com.shivhax.airveil` operation. No permission database was edited directly. The user approved the replacement identity, and an actual ScreenCaptureKit shareable-content request succeeded. Build 0.2.0 (2) was then installed without resetting permission. Its code hash differs from the approved build, its designated requirement is identical, it satisfies the old requirement, and the launched update reports screen access allowed. The updated build subsequently started live capture successfully with no new approval. Runtime state reported build 2, captureRunning/captureReady true, no capture error, and screenPermission true. The wearer confirmed that actual desktop blur sweeps correctly in both directions.

Automatic tracking is now started in normal application startup, independently of diagnostics. The installed app found the worn AirPods without a Connect button and received approximately 47–50 samples/s. Connection callbacks and timed retries recover motion automatically; center remains an explicit user choice. Wake detection restarts the sensor, while the desktop effect stays paused until recalibrated and enabled. Physical reconnect/wake acceptance remains pending.

Whole-screen mode now uses a directional sweeping edge instead of equal blur across both halves. Updated actual-GPU tests pass at 1x and 2x for quarter, half, and three-quarter sweep positions, mirrored direction, monotonic coverage, exact clear/full endpoints, and smooth reversal. The same mode is forwarded to both the app preview and desktop overlays.

Identity update evidence: approved build code hash `c379ab4f7bd2f8139ca5d17f875f31d4a723aea5`; updated build code hash `5c475b4edfb66470bdc717a56f234b9146b73f37`. Both use the same certificate-bound designated requirement. Private signing credentials are outside the repository and were not included in this evidence.

During live testing, a transient delayed-motion event invalidated calibration and activated the documented protective cover. Fresh samples recovered automatically; a subsequent Set center restored tracking. The final inspected UI showed Following your head, Live desktop capture, and Whole-screen sweep enabled. This observation does not establish sustained calibration reliability.
