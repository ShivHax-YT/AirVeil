# Energy-aware operation

## Recommendation

Introduce **Energy use: Automatic / Smoothest / Reduced** and change only the requested desktop-capture cadence in the first implementation. Preserve the current head-motion update rate, animation clock, tracking freshness rules, camera evidence requirements, AirPods removal behavior, input blocking, and all tutorial behavior. This is a focused extension of the earlier [feature research](FEATURE-RESEARCH-2026-09.md), with a smaller initial scope than its longer-term suggestions for preview and decorative animation.

Automatic should request up to 60 frames per second normally, and up to 30 when macOS reports Low Power Mode or serious/critical thermal pressure. Reduced should request up to 30 continuously; Smoothest should retain the existing request of up to 60. These are requested capture ceilings, not measurements or guaranteed delivery rates. The 30-frame choice is a conservative engineering starting point, not an Apple-prescribed threshold or demonstrated battery improvement.[^1][^2]

| Mode | Normal or fair thermal state | Low Power Mode | Serious or critical thermal state |
|---|---:|---:|---:|
| Automatic | Up to 60 fps | Up to 30 fps | Up to 30 fps |
| Smoothest | Up to 60 fps | Up to 60 fps | Up to 60 fps |
| Reduced | Up to 30 fps | Up to 30 fps | Up to 30 fps |

The explicit Smoothest selection keeps its stated behavior; macOS can independently constrain actual performance. Automatic is the recommended default. Do not infer Low Power Mode from being unplugged or from a guessed battery threshold. Fair thermal state alone should not alter this first version: Apple's SDK recommends deferring non-visible work at fair and reducing CPU/GPU work or frame rates at serious. At critical, the proposed reduction addresses discretionary desktop sampling; it is deliberately not a comprehensive thermal-management system.[^3]

## Platform support

`ProcessInfo.isLowPowerModeEnabled` is available from macOS 12, and `thermalState` from macOS 10.10.3. Both fit AirVeil's macOS 14 baseline. Unsupported/unknown power-mode state reads false; unsupported/unknown thermal state reads nominal. Listen to `NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification` using the default notification center, then reread both properties. Apple's headers state that notifications arrive on a global dispatch queue, so observable UI and capture-policy changes must cross to the main actor.[^3][^4]

Prefer notification-driven observation over a repeating polling timer. Read initial state, refresh on return from sleep or session inactivity, deduplicate unchanged effective cadence, and remove observers at teardown. Isolate state reading behind injectable inputs so tests can exercise all thermal levels without heating the computer or changing its power settings. Keep unknown future thermal cases conservative and explicitly tested rather than crashing.

ScreenCaptureKit's `minimumFrameInterval` controls the desired minimum gap between delivered frame updates. Apple documents `1/60` as up to 60 fps; desktop content may produce fewer updates. Its WWDC22 example changes resolution and frame interval using `updateConfiguration` on a running stream without recreating it. The installed macOS 26.5 SDK exposes the Swift async form `updateConfiguration(_:)`, with failure delivered as an error.[^1][^2][^5]

## Existing rendering behavior

The inspected baseline sets `minimumFrameInterval` to `1/60` for every selected display. `DisplayCaptureSink` retains valid frames during idle capture messages. `VeilMetalView` is already demand driven: mailbox arrivals coalesce redraws, and Gaussian blur is recomputed when source content or blur parameters change. `AppModel` separately animates veil coverage through a display link and pauses it when the effect settles.[^6]

Consequently, fewer changed desktop frames can reduce copying and blur work while the coverage edge continues responding to head motion at its existing cadence. The likely benefit is largest with changing content behind an active blur and may be small on a static desktop. Lower source cadence can make scrolling or video behind the blur look less smooth. This mechanism does not prove lower total energy use, and it does not justify a claim that the current renderer is continuously wasting work.

Do not lower the model's display-link cadence in this change: that path also invokes tracking safety checks and keeps coverage and pointer-blocking geometry coordinated. Do not alter Metal resolution, queue depth, frame validation, blur strength, shader behavior, or source-frame retention. Keep opaque-cover behavior unchanged, including its existing capture dependency.[^6]

## Safe stream updates

Use one serialized reconciliation operation per active capture generation. The operation captures stream/session identity, applies the latest desired cadence, awaits completion, and then checks that the same generation is still active before publishing success. While an update is pending, newer mode/system changes should replace the desired value, not create overlapping configuration calls. After completion, reconcile the newest value once. Identical notifications must do no work.

Construct fresh configurations through the same narrow factory used at startup, preserving display pixel dimensions, BGRA format, sRGB color space, disabled cursor/audio, and queue depth of three. `SCStreamConfiguration` inherits `NSObject` without an advertised `NSCopying` contract in the inspected header; do not assume an independent copy. Avoid mutating a configuration object that an outstanding operation may still consume.[^5][^6]

Stopping, sleep, capture failure, display changes, or a new start must invalidate obsolete work immediately. A cancelled Swift task is insufficient protection by itself because the underlying asynchronous operation may still complete. Old completions must not update a new session, restore windows, change readiness, or restart capture. Startup must converge on the latest requested cadence even if the choice changes while `startCapture` awaits completion.

An energy-configuration error is distinct from a failed capture stream. Preserve the existing functioning stream and report that the energy change could not be applied. Do not route a rejected optional update through the capture-failure shield or silently claim the requested cadence is active. Track successfully applied values, including partial multi-display success. Avoid unlimited retries; a later explicit change or a new capture session can retry. Genuine stream errors retain their existing safety path.

## Settings experience

Place one native, clearly labeled picker beside the existing visual-effect preferences. Use brief descriptions: **Automatic** adapts desktop updates to Low Power Mode and thermal pressure; **Smoothest** retains the usual desktop update rate; **Reduced** requests fewer desktop updates. A secondary line should state the current reason and distinguish requested, applying, and failed states where necessary. Keep technical frame-rate detail secondary rather than competing with the controls.

Persist the selected mode, default missing or invalid values to Automatic, and include the choice in the Settings walkthrough without replaying completed tutorials. Respect native keyboard interaction, accessible names, sufficient contrast, and Reduce Motion. No new permission, network activity, telemetry, brightness adjustment, or camera session is required.

## Validation gates and remaining evidence

Before delivery, test the complete mode/state matrix, invalid persisted values, duplicate notifications, rapid 60→30→60 changes, startup changes, update rejection, multiple displays, teardown during an await, and stale completion after restart. Assert preservation of all non-cadence configuration fields. Rerun existing capture, renderer, tracking, centering, removal, and tutorial suites; compile for the macOS 14 deployment target. Render Settings to check labels and layout, then verify native picker persistence.

Physical acceptance should compare repeated runs with the same Mac, displays, brightness, background apps, content, and scripted motion. Include static text, scrolling, video, partial blur, whole-screen blur, and no visible veil. Record capture rate, source copies, Gaussian passes, CPU/GPU behavior, and head-motion-to-coverage latency. Compare Activity Monitor energy trends and appropriate Instruments CPU/Metal traces; the archived Mac energy guide supports these tools, but its historical UI details may differ today.[^7]

Apple's current Power Profiler documentation explicitly lists iPhone/iPad support, so it should not be presented as a verified macOS measurement route.[^8] Automated state tests and reduced frame requests establish behavior; they cannot establish battery-life savings or physical AirPods responsiveness. Report those limits until controlled hardware measurements exist.

## Sources

[^1]: Apple. [SCStreamConfiguration.minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval). Undated API documentation; semantics also verified in installed macOS 26.5 SDK, `ScreenCaptureKit.framework/Headers/SCStream.h`, lines 219–222.
[^2]: Apple. [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/). WWDC22, 2022; configuration and live-update examples around 28:46–30:08. Accessed September 14, 2026.
[^3]: Apple. Installed macOS 26.5 SDK, `Foundation.framework/Headers/NSProcessInfo.h`, thermal/power state declarations and notification comments, lines 202–252. Local primary API contract inspected September 14, 2026. Web entry: [ProcessInfo.thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property).
[^4]: Apple. [ProcessInfo.isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled). Undated API documentation; availability, fallback, and notification behavior verified in the same Foundation SDK header.
[^5]: Apple. [SCStream.updateConfiguration(_:completionHandler:)](https://developer.apple.com/documentation/screencapturekit/scstream/updateconfiguration(_:completionhandler:)). Undated API documentation; installed macOS 26.5 SDK `SCStream.h`, lines 185–189 and 494–500, verifies inheritance and async/error contract.
[^6]: AirVeil. Local source baseline inspected September 14, 2026: [DesktopOverlayController.swift](../Sources/DesktopOverlayController.swift), [AppModel.swift](../Sources/AppModel.swift), and [VeilMetalView.swift](../Sources/VeilMetalView.swift). These are code observations, not measured performance results.
[^7]: Apple. [Energy Efficiency Guide for Mac Apps: Monitor Usage Regularly](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html). Archived guide, 2016. Activity Monitor and Instruments measurement guidance; accessed September 14, 2026.
[^8]: Apple. [Measuring your app's power use with Power Profiler](https://developer.apple.com/documentation/Xcode/measuring-your-app-s-power-use-with-power-profiler). Undated documentation; current overview lists iPhone with iOS 26 and iPad with iPadOS 26. Accessed September 14, 2026.
