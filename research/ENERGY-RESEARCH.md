# AirVeil energy use and rendering architecture

## Findings and priority

AirVeil has two distinct energy problems to address: unnecessary interface work while capture is paused, and expensive full-resolution image processing while capture is active. The paused-state problem is supported by a live CPU sample, not merely inferred from the renderer. The first implementation priority should therefore be separating high-frequency motion/render state from the settings interface and stopping invisible or unchanged visual updates. Optimizing Gaussian blur alone cannot explain or fix a paused app that is still spending substantial CPU time in SwiftUI layout.

The existing center-retention work must remain intact. Keeping a copied center and an uninterrupted headphone-motion session is functionally different from redrawing a settings window. The app can preserve that session while eliminating unnecessary UI and GPU work. Energy changes should follow the centering correction, with independent validation so a lower energy score cannot conceal a return of the centering bug.

The most promising changes, in order, are:

| Priority | Change | Evidence and expected effect |
|---|---|---|
| 1 | Stop broadcasting motion and animation changes through the entire settings model; update only the visible preview and small changed status values | Live paused sample contains substantial SwiftUI graph/layout work; broad invalidation is directly present in source |
| 2 | Use demand-driven drawing and a display clock only while an actual animation is converging; suspend the settings preview when hidden | Every Metal view and the coordinator currently keeps its own periodic draw/update source running |
| 3 | Add transparent and genuinely solid-output fast paths before capture blits and Gaussian work | Every complete captured frame currently computes all three blur levels even if no blur is visible |
| 4 | Compute medium/strong blur at smaller working resolutions while preserving the native sharp path and native mask | Three full-size blur textures are recomputed for every processed new frame |
| 5 | Separate content refresh cadence from head-driven edge animation | All selected display streams request up to 60 new full-resolution frames each second, independently of content needs |
| 6 | Reuse damage information and tighten texture usage after the simpler improvements are measured | Potential further bandwidth savings, but damage handling is more complex with newest-frame coalescing and blur support regions |

These are engineering priorities rather than measured speedup claims. No production source was changed for this report, and no additional live capture, camera session, power action, or performance benchmark was started.

## Observed energy and CPU evidence

During the September 13, 2026 investigation, Activity Monitor showed AirVeil Energy Impact **1556.2** and 12 hr Power **346.90**. The contemporaneous app state was paused, with capture not ready and fresh headphone motion; a process snapshot showed **36.1% CPU**. These observations corroborate the reported 1000–2500 Energy Impact range, but do not establish a continuous drain rate or the energy consumed by each component.

A subsequent ten-second series of process CPU snapshots, still with capture paused and motion fresh, averaged **53.76%**, with a **50.8–57.8%** range. This is a separate observation interval, not a revision of the earlier single snapshot. Attempts to close or minimize settings did not establish that the window was hidden, so there is no valid visible-versus-hidden comparison yet. The observed process was then stopped to avoid continued energy use during development.

Apple defines Energy Impact as a relative measure of current application energy consumption. Its 12 hr Power column is an average over the previous 12 hours, or since startup. Neither number should be presented as watts, battery percentage, or a directly convertible battery-runtime estimate. A recent improvement should be assessed with current Energy Impact and controlled CPU/GPU observations, not expected to erase the historical average immediately.[^1]

The existing local sample, `build/airveil-energy-before.sample.txt`, identifies installed AirVeil **0.6.0 (7)** on macOS **26.6.2**, sampled at approximately 1 ms intervals at 14:15 local time. It contains 2,070 main-thread samples. One nested path contains 620 samples through `NSDisplayCycleFlush`, 559 through `ViewGraph.updateOutputs`, and 537 through `StaticBody.updateValue`. These are nested stack counts: they must not be added together or interpreted as separate percentages of total app energy. The sample localizes substantial observed work to display/UI updates, but does not by itself identify which publisher initiated each update.

This distinction changes the optimization order. In the recorded paused state, desktop capture and its Gaussian pipeline are not the immediate explanation for the observed main-thread layout cost. The existing native-resolution GPU benchmark is useful for active-renderer comparisons, but cannot substitute for this paused-state diagnosis. Likewise, the older approximately 1.1% paused CPU snapshot in `validation/STATUS.md` occurred under different conditions and does not disprove the new observation.

Apple's current rendering guidance specifically identifies unnecessary redraws and frequent SwiftUI updates as sources of CPU/GPU power use. Its SwiftUI performance tools connect costly body evaluations to the state changes that caused them, making UI update frequency a suitable next measurement.[^2][^3]

## Source-level causes

### Whole-interface invalidation from motion and smoothing

`Sources/AppModel.swift:115–117` subscribes to `motion.objectWillChange`, throttles it to 100 ms, and then calls both the model's `objectWillChange.send()` and `stateChanged`. `Sources/SettingsView.swift:24` observes the entire model. This means a stream of telemetry changes can invalidate the full settings view even when most controls and labels have not changed. The throttle bounds this route at roughly ten deliveries per second; it does not make those deliveries narrow or cheap.

There is a second route. `AppModel.swift:169–188` installs a display link with a preferred 60 Hz cadence, computes smoothing each tick, and publishes `strengths` whenever its components change by more than 0.00001. The broad model is still the observation boundary for that animation. The preview needs smoothly changing strengths; the rest of the settings hierarchy does not need to be laid out at animation cadence. Pausing desktop capture does not stop this clock, and the preview may continue following live motion.

`Sources/AppDelegate.swift:62–66` additionally assigns the settings window's level and the menu-bar image, title, and tooltip whenever `stateChanged` runs, even if their effective values are unchanged. This is a concrete redundant call path, although the current sample does not quantify its individual contribution or prove that every assignment causes WindowServer work.

The appropriate fix is to separate state by consumer. Keep the latest pose and smoothed renderer strengths outside the broadly observed settings object. Send these values directly to a small renderer/preview coordinator. Publish a compact, equatable UI snapshot only when the values actually displayed have changed: for example, rounded angle text, connection/reference status, and activation state. Scope the live angle indicator separately from static controls. Do not simply slow all motion handling; that would sacrifice responsiveness while leaving the dependency structure intact. Apple recommends reducing unnecessary view dependencies and narrowing which changes cause updates.[^4]

The menu bar can keep a last-rendered status key and avoid reassigning identical image/title/tooltip/window-level values. Its relevant state changes are discrete. A 50 Hz pose stream does not change whether the effect is enabled or which status icon is needed.

### Multiple continuously running visual clocks

`Sources/VeilMetalView.swift:63–65` configures each view for unpaused 60 Hz rendering, with `enableSetNeedsDisplay = false`. The preview and each selected display use this class. `draw(in:)` correctly returns before drawable acquisition when `needsRender`, `blurDirty`, and the frame mailbox are all unchanged (`191–196`). That avoids redundant GPU submissions, but the periodic update source still runs. The coordinator also has its own display link.

Apple documents three supported MTKView modes: a periodic loop, invalidation-driven drawing with both `isPaused` and `enableSetNeedsDisplay` enabled, and explicit drawing with the loop paused. Demand-driven drawing is a supported workflow; it does not require replacing MetalKit or relying on a private API.[^5]

Switching `isPaused` on by itself would be incomplete in the current implementation: the mailbox has no notification callback, so new capture frames would not awaken rendering. A correct conversion needs a coalesced invalidation path for a new frame, a changed effect, and drawable-size changes. It must schedule the main actor after releasing the mailbox lock and allow at most one pending redraw notification. If the two-command in-flight limit temporarily prevents a submission, a completion must schedule the still-dirty work instead of losing it.

For head-motion smoothing, one display-synchronized coordinator can run while the current value differs meaningfully from its target, draw the changed overlays, and stop after convergence. A new pose or control change restarts it. A static desktop with a held head position then needs no GPU redraw. A changing desktop can request one composition per accepted content frame without requiring a permanently active second clock per view.

The settings window needs an explicit visibility policy. `SettingsView` currently has no preview suspension on disappearance or window occlusion. AppKit exposes window occlusion notifications specifically so applications can stop expensive work people cannot see.[^6] Use those notifications for the settings preview; do not apply the settings-window visibility to desktop overlays, which may still be visible and doing requested work in other apps. Closing the settings window must not stop the headphone stream or the active desktop effect.

### Full-resolution blur work even when output is clear

Each complete ScreenCaptureKit frame replaces the mailbox's pending image (`DesktopOverlayController.swift:78–87`). `VeilMetalView.encode` then maps the CVPixelBuffer, copies the entire image to an owned texture, and marks the blur dirty (`141–153`). Dirty processing runs all three Gaussian kernels across full-size textures (`162–175`). There is no branch before this work for zero left/right coverage, nor for a shield whose output is independent of the source.

The fragment shader returns a constant for a shield (`Resources/Veil.metal:21`), but this happens after the blit and blur passes have already executed. Its neutral transparent return similarly happens after those passes; the shader also samples the sharp image before checking zero coverage (`37–39`). The latter sampling can be moved behind the coverage decision when the preview base is not required, but avoiding the entire unused image-processing pipeline is the larger opportunity.

A transparent desktop overlay should clear once when it becomes neutral, keep the newest pending source bounded, and skip source copying, Gaussian work, and presentation until visible output requires them. Before blur becomes visible again, process the latest frame and regenerate any stale levels. Preserve first-frame/readiness semantics: receiving and validating capture is different from requiring three invisible blur passes. Failure handling must still clear or show its deliberate fault state correctly.

A true constant full-screen shield needs only a solid draw or the existing AppKit cover. The **Opaque cover** option is not automatically such a case: its shader mixes source-derived colors at intermediate coverage, so the whole option cannot bypass capture unconditionally. A half-screen mask also still needs the source wherever it has nonconstant visible color. Fast paths must be selected from actual output dependency, not just an option name.

### Resolution and bandwidth multiply the cost

`DesktopOverlayController.swift:246–253` configures capture at the filter's full point size times its pixel scale, BGRA, queue depth 3, and a 1/60 minimum frame interval. `VeilMetalView.allocate` creates one full-size source plus three equally large blur textures (`99–111`). Its blur sigma is converted from points to source pixels (`163`), so the 2× display both quadruples the pixel count relative to its point grid and doubles sigma in pixel units.

For the previously observed 1470×956-point 2× display, the source is 2940×1912, or 5,621,280 pixels. Four BGRA textures represent approximately **89.94 MB** of logical image storage, excluding capture surfaces, drawables, and implementation overhead. A full-frame read-and-write copy at 60 processed frames/s represents approximately **2.70 GB/s** of logical traffic before blur sampling, blur destination writes, or composition. These calculations describe workload scale, not measured memory-controller traffic: hardware caches, compression, scheduling, and idle capture affect the actual result.

The current implementation already caches blur levels across changes in head angle, and caches MPS kernel objects when sigma is unchanged. These are good properties to preserve. Apple describes `MPSImageGaussianBlur` as a fast approximate Gaussian implementation; replacing it with a hand-written many-tap shader is not justified solely by the energy report.[^7] The avoidable quantity is how many full-size pixels are processed, how often, and whether the result is needed.

Use a blur-only multiresolution bank: retain the native sharp source for the near-clear blend, retain native-resolution output/mask geometry, and calculate the broader Gaussian levels at half or quarter dimensions. Halving each dimension gives one quarter as many working pixels; quartering gives one sixteenth. These are pixel-count ratios, not promised runtime speedups. Sampling smaller textures can reduce bandwidth, but creating the reduced images also has a cost.[^8]

The blur strength must remain expressed in display points. If a working level is reduced by factor `d`, its Gaussian sigma must be converted to that working pixel grid; copying the old sigma into the smaller texture would make the apparent blur too large. Downsampling and upsampling contribute their own smoothing and must be accounted for through image comparisons, especially for the softest level. Preserve the exact native alpha feather so pointer bounds continue to match visible coverage.

A cascaded, properly filtered reduction should be compared with a resampling filter rather than blindly using a sparse sample of the source. Apple's Lanczos scaler can downsample directly, but documents potential ringing near sharp edges; it is not automatically the best choice for high-contrast desktop text.[^9] A strong-blur pyramid can be inexpensive without changing the sharp path. Require tests of small text, checkerboards, line edges, and moving content at both backing scales before lowering capture resolution globally.

### Capture cadence and damage

The compositor's moving edge and the captured desktop's content do not need identical update rates. A useful first candidate is 30 Hz content capture with a 60 Hz head-driven edge while it moves, measured against the current 60/60 configuration. Lower content cadence can reduce Gaussian rebuilds on video or scrolling content without quantizing head motion to that same cadence. It can also add content lag, so the tradeoff must be checked on moving windows and video rather than assumed invisible.

ScreenCaptureKit exposes minimum frame interval and output dimensions explicitly. Apple's examples distinguish high-resolution, low-motion content at a lower frame rate from high-motion content at a higher frame rate and reduced resolution. It also supports changing configuration while streaming.[^10] The local SDK documents the interval as an update throttle. Online and local header descriptions disagree about the default value, but AirVeil explicitly supplies 1/60, so its current request and an explicit 1/30 proposal are unambiguous.

The capture sink already ignores idle samples; it should continue doing so. A static source should not be declared lost because it produces no changed frame. ScreenCaptureKit supplies dirty rectangles identifying updated content, which can support avoiding irrelevant work.[^11]

Damage optimization needs particular care in this app. The newest-frame mailbox deliberately drops intermediate frames. The newest frame's dirty rectangles alone may describe only the change since its immediate predecessor, not every change since the app's last processed frame. A partial-update design must union damage across all discarded frames, track a contiguous source revision, or fall back to full processing after a gap. Blurring also spreads changes beyond a dirty rectangle, so any cropped update needs a conservative filter-support halo. These complexities make damage-aware processing a later step, after neutral bypass, demand rendering, and smaller blur levels are measured.

### Texture and diagnostic details

The Metal view sets `framebufferOnly = false` (`VeilMetalView.swift:61`), although its live drawable is only a render target followed by presentation. Its offscreen test creates a separate texture for readback. Apple documents that framebuffer-only drawables allow display optimizations and that disabling this has a performance cost.[^12] Enabling it is a small, concrete candidate with limited architectural impact.

The owned source texture uses shared storage and broad shader-read/write/render-target usage even though its live path is GPU blit destination and shader source. CPU writes are used for the initial fallback pixel, while synthetic loading has a separate path. Consider separating initialization/test convenience from the live resource's storage/usage contract. Private GPU resources can receive additional optimizations, but this is secondary to avoiding whole passes and should be measured rather than assumed to solve the main problem.[^13]

The diagnostics launch option writes an atomic JSON snapshot every 0.5 seconds (`AppDelegate.swift:31–35,121`). This is intentional testing overhead rather than always-on product behavior. Normal-launch energy measurements should therefore include a run without that option, with any instrumentation enabled identically for before/after comparisons. Essential sensor freshness/removal safeguards must remain responsive; optimization should target redundant periodic work first. Apple's timer guidance recommends event-driven work and stopping unneeded timers, with tolerance for noncritical periodic tasks.[^14]

## What the macTilt reference actually establishes

The original local checkout is still at commit `aa87e34755b88d37dcaae739b1645a504efe0a97`. `MetalFoldView.swift:79–97` has explicit resume/suspend rendering, initializes paused with framebuffer-only drawables (`125–128`), and adapts fragment sample count (`55–59`). These are useful design examples for controlling unnecessary work.[^15]

However, `OverlayWindowController.swift:237–249` explicitly freezes one screen frame at fold start, rather than continually reflecting the underlying desktop. Its warm ScreenCaptureKit stream still requests native output at 60 Hz (`StreamCapture.swift:157–183`). The reference's brief lid animation therefore does not establish an energy baseline for hours of live desktop blur. Copying its frozen image behavior would fail AirVeil's live-content requirement.

The reference also records why globally halving its source produced visible blocks and incorrect apparent blur: its sharp sampling and radius assumptions depended on native pixels (`OverlayWindowController.swift:359–365`). That supports preserving AirVeil's native sharp/geometry path when reducing only the blur workspace. The source is an implementation example, not proof of measured efficiency on this Mac, and no code needs to be copied.

## Proposed operating model

| State | Motion/reference | Desktop capture | Visual work |
|---|---|---|---|
| Paused, settings hidden | Preserve the requested sensor stream and current reference; maintain necessary freshness/removal checks | Stopped | No preview display clock, no settings telemetry redraw, status only on actual changes |
| Paused, settings visible | Same sensor behavior | Stopped | Only visible preview/HUD changes; static controls remain outside the animation dependency |
| Enabled, centered | Same sensor behavior | Keep a bounded newest source; investigate a lower refresh policy separately | Clear once; no Gaussian or repeated transparent presentation |
| Enabled, head turning | Same sensor behavior | Content cadence chosen independently | Display-synchronized mask animation using cached blur levels; regenerate levels only for accepted changed content |
| Enabled, held turn/static content | Same sensor behavior | Idle/newest-frame handling | No repeated draw once the effect has settled |
| Enabled, held turn/changing content | Same sensor behavior | Bounded content updates | Blur only needed levels at chosen working sizes, then compose |
| Sleep, inactive session, loss, or explicit pause | Follow existing retained-reference and recovery rules | Stop/release according to existing policy | Hide/clear synchronously, stop drawable work, reject stale callbacks |

A retained source while enabled is already part of the live design; explicit Pause or session loss must continue releasing sensitive frames. None of these states requires a continuous camera. If a future centering correction uses a short camera check, its energy and lifecycle must be evaluated separately rather than folded into the current no-camera baseline.

## Validation sequence after the centering fix

First establish a repeatable baseline with the same display arrangement, brightness, power source, app visibility, diagnostic setting, and foreground workload. Record which displays are selected and whether the effect is neutral, moving, or held. Separate six cases: paused/hidden; paused/visible with live motion; enabled/neutral; held blur/static desktop; held blur/changing desktop; moving edge/changing desktop. Repeat the active cases on one and two displays. A single screenshot of Energy Impact is useful symptom evidence but insufficient for a before/after claim.

Measure current Energy Impact over comparable settled intervals, average CPU, UI update counts, capture complete/idle counts, processed source revisions, draw submissions, blur rebuilds, and GPU duration. Keep counters aggregated; no desktop recordings or pose history are needed. Use the existing sample to compare CPU paths and, when available, SwiftUI Instruments to attribute dependency updates. GPU command duration is a component measure, not end-to-end sensor/display latency or total energy.

Then make one coherent change at a time:

1. Narrow UI publication, deduplicate status, and stop invisible preview work. Verify paused hidden operation has no periodic visual submissions or settings-layout activity, while connection/removal behavior still works.
2. Convert to coalesced demand rendering. Verify a fresh frame, effect change, and resize each wake a paused view; a temporarily busy GPU does not lose the last redraw; no work appears after stop.
3. Add neutral/solid bypass. Assert zero Gaussian passes for transparent output, one clear on transition, and latest-source content when blur becomes visible again.
4. Add lower-resolution blur levels and explicit resource optimizations. Compare GPU duration on identical synthetic moving sources, then inspect native 1×/2× images for halos, aliasing, alpha/mask changes, and wrong blur scale.
5. Compare content cadences on scrolling/video while keeping edge animation responsive. Adopt a lower default only if the visual result remains acceptable.

Existing direction, variance interpolation, endpoint, clear-alpha, live-texture replacement, input-region, release/reuse, startup cancellation, and center-retention regressions remain required. Repeat the wearer-facing original-center check and global pause behavior after integration. A successful energy result must improve the measured paused and active scenarios without freezing content, dropping motion safety, or changing the saved zero.

The available evidence supports this implementation order. It does not yet support a numerical battery-life improvement, a target Energy Impact score, or a claim that changing capture from 60 to 30 Hz alone fixes the reported drain.

## Sources

Apple web documentation was checked September 13, 2026. Current API pages are used where available; the older Energy Efficiency Guide is identified as archived guidance. Local source evidence refers to the current AirVeil working tree and the pinned macTilt commit. The local sampled profile is an ignored diagnostic artifact and should not be published with private machine metadata.

[^1]: Apple Support. [View energy consumption in Activity Monitor on Mac](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac). Current Energy Impact and historical average definitions.
[^2]: Apple Developer Documentation. [Improving your app’s rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency). Unnecessary redraws, update regions, animation duration and frequency.
[^3]: Apple. [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/), WWDC25. Update groups, view-body work, dependency analysis, and CPU correlation.
[^4]: Apple. [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/), WWDC23. Narrow view dependencies and reduce unnecessary updates.
[^5]: Apple Developer Documentation. [MTKView](https://developer.apple.com/documentation/metalkit/mtkview/). Periodic, invalidation-driven, and explicit drawing modes.
[^6]: Apple Developer Documentation. [NSWindow.didChangeOcclusionStateNotification](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification). Visibility-dependent suspension of expensive work.
[^7]: Apple Developer Documentation. [MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur). Approximate Gaussian and performance characteristics; no AirVeil-specific speed claim.
[^8]: Apple Developer Documentation. [Improving texture sampling quality and performance with mipmaps](https://developer.apple.com/documentation/metal/improving-texture-sampling-quality-and-performance-with-mipmaps). Smaller texture levels, sampling quality, and bandwidth.
[^9]: Apple Developer Documentation. [MPSImageLanczosScale](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagelanczosscale). Resampling quality, relative cost, and ringing limitations.
[^10]: Apple. [Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/), WWDC22, configuration discussion around 8–10 minutes; [minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval). Local macOS 26.5 SDK `ScreenCaptureKit.framework/Headers/SCStream.h`, lines 210–222 and 275–279, checked for explicit output-size, interval, and queue semantics.
[^11]: Apple. [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/), WWDC22. Dirty rectangles, output geometry, and sample metadata; [SCFrameStatus.idle](https://developer.apple.com/documentation/screencapturekit/scframestatus/idle).
[^12]: Apple Developer Documentation. [MTKView.framebufferOnly](https://developer.apple.com/documentation/metalkit/mtkview/framebufferonly). Drawable usage and display optimization.
[^13]: Apple Developer Documentation. [MTLStorageMode.private](https://developer.apple.com/documentation/metal/mtlstoragemode/private) and [Optimizing texture data](https://developer.apple.com/documentation/metal/optimizing-texture-data). GPU-oriented resource optimization depends on use and hardware.
[^14]: Apple, archived Energy Efficiency Guide for Mac Apps. [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) and [Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html), 2016-era guidance. Event-driven work, stopping unneeded timers, and appropriate tolerance.
[^15]: lqSky7. [iphone-duo-macos-animation at aa87e34755b88d37dcaae739b1645a504efe0a97](https://github.com/lqSky7/iphone-duo-macos-animation/tree/aa87e34755b88d37dcaae739b1645a504efe0a97). Locally inspected `Sources/MetalFoldView.swift`, `Sources/OverlayWindowController.swift`, and `Sources/StreamCapture.swift`; direct source evidence, not a measured energy benchmark.
