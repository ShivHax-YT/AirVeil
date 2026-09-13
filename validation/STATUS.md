# AirVeil validation status

## Verified

- Four cited research reports completed and reviewed before app implementation.
- Native macOS app builds against macOS 26.5 SDK with deployment target 14.0.
- App installed at `/Applications/AirVeil.app`, signature verified, and launched.
- 2,094 deterministic synthetic motion/math assertions, 45 motion-delivery lifecycle assertions, and 16 real-AppModel lifecycle assertions pass. The lifecycle suites use synthetic input or stubbed device/capture APIs.
- Actual GPU render tests pass at 1x and 2x for transparent neutral pixels, opposite-side masks, monotonic/mirrored feather, premultiplied alpha, opaque source independence, full shield, and top-left image orientation.
- Running native settings window inspected visually; simulated left turn produces right-side blur with a clear left side.
- Independent reviews found and fixed run-loop freshness, terminal retry, buffered-sample lag, display-change reveal, preview failure-state, and shortcut-advertising issues.
- Private GitHub repository created using GitHub Desktop and research milestones pushed.

## Live evidence and remaining acceptance

The first integrated build received AirPods Pro 3 motion at approximately 49–52 samples/s from the left bud. The wearer confirmed that physical head motion blurred the in-app preview. The running app then reported successful live desktop capture and calibrated tracking. The Pause button was exercised and returned the capture status to paused. These are real runtime observations, separate from synthetic tests.

The newest build adds whole-screen coverage, reset defaults, clearer calibration, and idle rendering improvements. Whole-screen preview and reset to 8° onset / 32° full angle / 32 pt blur / 12% feather / 70 ms response were verified through the running UI. Paused static app CPU was observed near 1.1% after optimization, compared with a prior snapshot near 38%; these snapshots are not a controlled energy benchmark.

Synthetic native-resolution GPU benchmark at the main display's 1920×1080, 1x mode: 120 changed frames, last observed median 0.773 ms and p95 2.995 ms. This measures blit + three Gaussian passes + composition, not real display FPS or sensor latency. Eight repeated renderer release/reuse cycles pass; late frames are rejected. See Tests/PerformanceTests.swift to reproduce.

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

## Reliability update 0.2.1 (build 3)

- Root cause of UI-induced delayed-motion warnings: acquisition callbacks were on the main queue and their receipt timestamps included UI scheduling delay. Collection now runs on a serial background queue. A bounded buffer delivers the newest pose while retaining intervening sensor gaps, source changes, invalid data, clock changes, and terminal errors. The watchdog consumes queued acquisition before checking freshness. Synthetic tests cover a one-second UI stall, menu-tracking coalescing, real sensor lag, gaps, source switches, reference jumps, invalid samples, terminal errors, and expired acquisition.
- Fixed a queued-start cancellation race: immediate Pause or shutdown before the async capture/access-check task begins now prevents that task from starting. The real AppModel tests fail when either entry guard is removed.
- Capture startup now rechecks display identity, exact frame, backing scale, generation, and failure state across each async boundary. This prevents starting a partially outdated display set or continuing after an early stream failure.
- Additional actual-GPU tests pass for newest captured-buffer selection, unchanged idle frames, 16 alternating live source images without retained trails, clear-side transparency, and resized source allocation.
- Build 3 installed and its actual ScreenCaptureKit access check passed without new permission. The running UI observed automatic AirPods motion at about 51 samples/s after reconnection and manual center selection.
- Main display inventory at test time: 1920×1080 at 1× and a second display at (1920, -239), 1470×956 points at 2×. Current live two-display alignment, fullscreen coverage, physical reconnection, and manual pause-key checks are requested from the wearer.
- Automated key injection from GitHub Desktop did not increment the app's new global-pause activation counter. This does not establish whether a physical hotkey is delivered; manual confirmation is pending. Registration itself succeeds.

All current automated suites and a complete signed build pass. The latest physical checks remain separate from this result.

A 90.2-second live observation of build 3 collected 178 fresh diagnostic snapshots: capture stayed ready in all 178; motion was fresh in 170 and calibrated in 148. Maximum added acquisition lag was 48.7 ms, with no delayed-motion warning in that interval. Eight snapshots were waiting for motion and 22 reported a head-reference jump; 30 snapshots used the protective cover. The wearer was carrying out requested physical checks, so this aggregate does not attribute the interruptions to a specific gesture or prove sustained calibration. Manual feedback is still pending. No head-pose history or screen image was saved in this aggregate.

## Wearer feedback and update 0.3.0 (build 4)

The wearer confirmed fullscreen blur on both connected displays and confirmed that the physical Control–Option–Command–P shortcut immediately clears it. Diagnostics independently recorded one global-pause activation and stopped capture. The wearer also reported a steady ten-second turn followed by a black screen that remained until Set center after reinserting a bud. This was not accepted as satisfactory recovery.

The new recovery policy automatically pauses and clears blur and pointer blockers when tracking becomes invalid. Fresh input alone does not invent a new reference; Set center resumes a pending interrupted effect, while manual Pause or changing display selection cancels that recovery intent. A changed reference therefore no longer leaves a persistent black cover.

The discontinuity detector now considers both adjacent angular velocities so an abrupt physical stop is not assessed using only a low final speed. Actual unexplained low-speed quaternion jumps still invalidate calibration. New referenceJumpCount/lastReferenceJump diagnostics record one event count plus the latest step/threshold/timing/rates, without a pose history. A sensor-origin reset remains unproven until live event evidence identifies it.

User-requested controls now include connected-display count, refresh, per-display selection persisted by UUID, and click/scroll blocking in blurred areas or the whole affected display. Nonactivating panels preserve keyboard focus and reserve menu/escape controls. Drags already started before interception may remain owned by the original application.

Automated validation passes: 2,094 math assertions, 52 motion-delivery assertions, 42 real-AppModel lifecycle assertions with entirely stubbed device/capture/preferences APIs, 690,785 input-region checks, actual-GPU input-mask cross-checks at 1×/2×, and prior live-texture replacement/resize tests. The new selected-display, pointer-interception, and automatic-clear behavior still need installed-app verification.

Build 4 is installed and strict signature validation passes with the existing identity. Actual ScreenCaptureKit access check passed without new permission. The running controls were inspected visually; selecting displays updated 2 → 1 → 0 → 1 → 2, and both were restored. The installed app currently reports two connected/two selected displays and pointer blocking enabled in Blurred area mode. AirPods motion is unavailable at this final setup check, so live selected-display capture, physical pointer interception, and new recovery behavior await the wearer's requested checks.
