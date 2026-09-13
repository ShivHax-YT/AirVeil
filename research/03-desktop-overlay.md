# macOS Desktop Blur Architecture

## Recommendation

Build the macOS renderer in native Swift with ScreenCaptureKit, AppKit, MetalKit, and Metal Performance Shaders. Capture each selected display while excluding this application's windows, process the newest valid frame entirely on the GPU, and present only the obscured region in a transparent, click-through overlay. Head tracking supplies a signed, calibrated yaw value; it does not need to know anything about screen capture or rendering.

This can produce the requested opposite-side effect with a genuinely clear unaffected area: a leftward turn progressively blurs the right half, and a rightward turn progressively blurs the left half. It changes the displayed pixels for everyone looking at that display. It cannot selectively hide pixels from a person standing on one side while preserving those same pixels for the owner; that would require directional display hardware. Blur also remains an obscuration effect, not a guarantee that text is unrecoverable. An optional opaque mode should be the explicitly stronger alternative.

The architecture is supported by Apple's display/application filtering, GPU-backed capture buffers, and click-through window APIs. Its exact frame latency, full-screen coverage, privacy effectiveness, and AirPods direction mapping still require on-device measurement. These are acceptance tests, not facts established by documentation.[^1][^2][^3]

## Evidence and version boundary

The inspected Mac runs macOS 26.6.2, build 25G83. The installed SDK exposes ScreenCaptureKit's macOS APIs including `pointPixelScale` and `contentRect` from macOS 14, `includeMenuBar` from 14.2, and AppKit `canJoinAllApplications` from 13. These availability values were checked directly in the installed public headers. Current web documentation also describes newer iOS 27 functionality; those future-platform entries do not establish support on this Mac or permission to overlay other applications on iPhone/iPad.[^14]

The implementation target is the explicitly installed macOS 26.5 SDK; its public headers separately confirm the same `pointPixelScale`, idle-status, and `canJoinAllApplications` behavior. Avoid accidentally adopting macOS 27-only APIs from the default SDK or current web documentation.

The reference project was inspected read-only at commit `aa87e34755b88d37dcaae739b1645a504efe0a97`. Its capture and Metal code provide useful engineering patterns, but its artistic fold behavior differs from a sustained privacy overlay. Implement original code from the public API contracts; this report provides no permission to copy reference-project source. No copied code, benchmark, or claim of successful full-screen operation is implied by this review.[^15]

## Rendering options

| Option | Supported behavior | Fit for this project |
|---|---|---|
| `NSVisualEffectView` with `behindWindow` | Native material that blends and blurs desktop/windows behind the host window; public `maskImage` controls material coverage | Good prototype or material fallback; exact blur sigma is not a public control |
| ScreenCaptureKit + Metal/MPS | Explicit input texture, blur strength, feathering, opacity, pixel geometry, frame cadence | Recommended production architecture |
| Repeated screenshots and CPU image processing | Can produce static blurred snapshots | Poor fit for continuous interaction; unnecessary copy/latency path |
| Private backdrop filters or SkyLight calls | Undocumented compositor behavior | Exclude from this application's supported implementation |

AppKit's material appearance depends on semantic material, appearance, active state, and other factors. This is useful for normal macOS surfaces, but does not give the app a stable mathematical relationship between yaw and blur radius. Screen capture plus a controlled shader makes that relationship testable.[^4][^14]

## Capture pipeline

Use one `SCStream` per selected active display and one renderer per display. Enumerate `SCShareableContent`, locate the own `SCRunningApplication` by current process ID, and construct `SCContentFilter(display:excludingApplications:exceptingWindows:)` with that application excluded and no exceptions. Apple documents application-wide exclusion; using it instead of a snapshot of window IDs avoids a design in which a newly created overlay is missing from the exclusion list.[^1][^5]

Build the own application/window objects before enumeration. If enumeration unexpectedly cannot identify the process, do not quietly proceed with an unfiltered full-display capture. Retry after the app has a visible setup window or use explicit known overlay-window exclusions, verifying that every overlay is represented before enabling the effect. Keep this failure visible in diagnostics.

`NSWindow.sharingType = .none` is not the foundation for avoiding recursion: the filter on this app's own stream is. Self-exclusion is also not a guarantee that a different application cannot capture the overlay or the original windows. Do not market the app as screenshot prevention.

Initial capture settings should be BGRA, audio off, microphone off, cursor off, and a 1/60-second minimum frame interval. A native live cursor must remain singular and responsive; rendering the captured cursor produces a second delayed cursor. Use queue depth three initially, and profile five if GPU pressure causes stalls. Apple's default is three and documented maximum is eight.[^6]

Derive output size from the selected filter's content rectangle and pixel scale, then validate against actual pixel-buffer dimensions and matching `NSScreen` geometry. Avoid multiplying a display's width by the *main display's* backing scale. Screens can differ in Retina scale, resolution, position, and rotation. Capture dimensions and overlay points are distinct coordinate spaces.[^7]

For each sample, inspect readiness, image buffer, frame status, and relevant frame geometry. New complete frames replace the most recent source. Idle means the display has not changed and should retain the existing valid image; it is not a failure. Blank, stopped, and suspended are distinct lifecycle conditions, not valid pixels to publish as new desktop content.[^8]

The callback should publish one newest frame, not enqueue an unbounded series of frames for the main thread. Separate capture lifecycle work from UI work, and tag asynchronous start/restart operations with a monotonically increasing generation. Stop and discard obsolete streams that finish starting after their generation has been invalidated. A delayed error from an old stream must not stop its successor.

## GPU ownership and blur

Map a valid `CVPixelBuffer` through `CVMetalTextureCacheCreateTextureFromImage`. Keep the returned `CVMetalTexture` alive until the GPU command buffer completes; keeping only its `MTLTexture` is insufficient. Apple specifically recommends releasing the Core Video wrapper from a command-buffer completion handler.[^9]

An additional GPU blit into an application-owned latest-frame texture is a reasonable deliberate tradeoff. It lets the app release ScreenCaptureKit pool surfaces promptly while retaining a valid source indefinitely when the desktop is static. It is still free of CPU readback. Use bounded resources and synchronization so a capture update cannot overwrite a texture that the renderer is sampling. Two or three owned slots with explicit command-buffer completion are preferable to unexplained global mutable texture state.

Use `MPSImageGaussianBlur` for the first production version. Apple supplies a fast approximate Gaussian kernel, suitable for ordinary image-processing precision; this avoids implementing a wide two-dimensional kernel from scratch.[^10] Retain a sharp native-resolution input for small-radius transitions and a half- or quarter-resolution path for stronger blur. Express sigma in screen points, then translate to the selected texture's pixels. Downsampling is an optimization to benchmark, not a reason to reduce the clear region's resolution.

The recommended renderer does not draw a captured sharp copy over the clear region at all. Clear-region fragment output is `(0, 0, 0, 0)`. On the covered side, output the blurred texture with the chosen opacity, using consistent premultiplied alpha. Configure the window, backing Metal layer, and drawable to support transparency; clear every frame to transparent. A black clear color or a fragment alpha of one across the screen will defeat the clear region even if RGB visually resembles the desktop.

A blur-only treatment should reach fully opaque *blurred-image* coverage inside its protected region once engaged. Merely fading a blurred image to 40% opacity leaves 60% of the sharp desktop visible underneath. The edge feather intentionally creates a transition zone, and that zone should not be described as fully protected.

## Motion-to-mask model

Use a renderer-independent convention: positive yaw means a verified physical turn to the right. The sensor adapter must establish and test this convention; the overlay must never infer direction from an unverified Core Motion sign.

Starting values for user testing are a 6-degree dead zone, full strength by 30 degrees, and a feather band occupying roughly 4–8% of display width. These are design recommendations, not physiological thresholds. A smooth monotonic transfer is:

```
t = clamp((abs(yawDegrees) - deadZone) / (fullAngle - deadZone), 0, 1)
strength = t*t*(3 - 2*t)
```

For a rightward turn, feather a mask over the left half; for a leftward turn, mirror it over the right. Keep the center boundary stable initially. Moving a boundary and increasing blur simultaneously adds an extra control variable that makes calibration and privacy testing harder. A later adjustable coverage control may move the boundary deliberately.

Smooth *time*, not frame counts: apply `a = 1 - exp(-dt/tau)` to strength or use a critically damped, non-overshooting response. Start with 60–100 ms smoothing and measure the resulting total response; capture, motion delivery, and display scheduling contribute additional delay. A fast attack and slightly slower release can obscure quickly without flickering on small return motions. Avoid spring overshoot that temporarily reduces coverage or flips the side.

Side changes must pass through the neutral dead zone. Hysteresis prevents toggling near the activation threshold. Clamp nonfinite input, reject stale/out-of-order samples, and reset calibration after reconnection. Stop using a stale AirPods sample as proof of the current head direction.

The draw cadence is separate from capture cadence. A static desktop can deliver idle frames while the head moves; the renderer must continue updating mask/blur uniforms smoothly from the retained source. `MTKView` supports both continuous drawing and explicit redraw behavior. When the head and source are unchanged, request-based redraw can reduce energy use; when motion is active, drive at the tested display cadence.[^11]

## Window and display behavior

Each overlay should be borderless, transparent, shadowless, non-key, non-main, and `ignoresMouseEvents = true`. That documented property allows pointer interaction with windows underneath.[^3] Keep actionable controls in a separate status menu/settings window. Do not intercept clicks on the protected side: the requested feature is visual obscuration, not an input lock.

Use each selected `NSScreen.frame`, not `visibleFrame`, because the latter omits menu-bar/Dock areas. Map screen identifiers to `SCDisplay.displayID`. Observe display-parameter changes and rebuild geometry, stream filters, and render targets after display removal, mode changes, rotation, mirroring, or docking. Mirror sets need validation to avoid redundant overlay/capture loops.

For desktop Spaces, start with `canJoinAllSpaces`, `stationary`, and `ignoresCycle`. For ordinary full-screen and Stage Manager eligibility, include `canJoinAllApplications` with appropriate `fullScreenAuxiliary` behavior. Apple's documentation expressly describes `canJoinAllApplications` for floating windows and system overlays, but eligibility language does not guarantee every application, exclusive fullscreen path, or system surface will be covered. Only one of `primary`, `auxiliary`, or `canJoinAllApplications` may be set.[^12][^14]

Choose and test a public window level above ordinary application windows. Do not use the reference project's private SkyLight space delegation or extreme `Int32.max` levels. The app should not attempt to replace, cover, or render the lock screen. System UI, secure dialogs, Mission Control, screen savers, and fast user switching require explicit validation and honest limitations.

## Lifecycle and failure policy

Maintain a visible state model: disabled, awaiting permission, awaiting headphones, calibrating, active, paused, and error. Screen Recording authorization is part of capture startup, and Apple notes that its sample requires restart after granting permission.[^1] Preflight can support the setup UI, but a successful stream and valid first frame provide stronger readiness evidence than a stored permission flag.[^13]

Screen or system sleep and session resignation should stop capture and drawing, release retained desktop images, and suppress overlays. On wake/session activation, start a new generation and require a fresh frame plus valid head state before normal rendering. `NSWorkspace` documents notifications for session switching and screen/system sleep; session switching notifications alone must not be advertised as a complete lock-state detector.[^16]

Handle stream errors and user-stopped sharing distinctly. Apple documents user cancellation as an expected, recoverable stop. Do not silently restart against a user's explicit stop action. Display the stopped state and require the normal enable/retry action.[^17]

An enabled privacy feature must not silently remove coverage when capture or motion fails. Recommended default during an unexpected active-session failure is an opaque neutral shield over the affected display, with a reachable status-menu pause/quit control and clear status. An explicit user disable should remove coverage immediately. Sleep/lock/session-switch behavior instead relinquishes to the OS; the app does not promise to cover secure system surfaces. This policy must be stated in onboarding and tested for recoverability so a fault cannot strand the user.

Do not classify a long interval without a complete frame as failure by itself: a static desktop can legitimately remain idle. Distinguish recent idle callbacks from no callbacks, stream inactivity/errors, and actual frame replacement. Clear cached images on session changes, rather than showing an old desktop after unlock or user switching.

## Performance targets and verification

No performance measurement has yet been made for this new app. A 3840 × 2160 BGRA buffer requires about 31.6 MiB; three such surfaces require about 94.9 MiB before owned textures, blur intermediates, or drawable storage. At 60 fps, one full-frame read is about 1.85 GiB/s. A 5K display, multiple displays, and extra blur passes increase these costs directly. These are arithmetic estimates, not observed app memory use.

Keep GPU work asynchronous, drop superseded input rather than blocking capture, and reuse textures/kernels. Do not call `waitUntilCompleted` from the main thread. Queue depth buys time for releasing shared surfaces, not lower latency. Profile CPU time, GPU duration, resident memory, input age, displayed-frame age, and command-buffer errors during sustained motion and scrolling. Apple explains that retaining capture surfaces too long can exhaust its surface pool and stall new frames.[^2]

The release gate should include the following evidence:

| Scenario | Required observable result |
|---|---|
| Center, then deliberate left/right turns | Correct opposite side every time; no change from roll/nod alone beyond validated tracking noise |
| Text/video scrolling under sustained yaw | Covered content remains live; clear region has no delayed copied pixels |
| Overlay shown before capture/restart | No repeated blur, darkening, hall-of-mirrors, or self-feedback |
| White/black edge markers and menu/Dock | Correct orientation, scale, coverage, and transparency with no seam |
| Static source with changing yaw | Smooth mask despite no new complete capture frames |
| Retina + non-Retina, rotated and negative-origin display | Every selected display uses its own correct geometry |
| Spaces, ordinary full-screen, Stage Manager | Coverage and pointer behavior recorded for each tested mode |
| Capture revoke/user stop, disconnect, sensor stall | Visible correct state; documented shield/pause behavior; controls recover operation |
| Sleep, wake, lock/unlock, fast user switch | No stale desktop exposure or private lock-screen API dependency |
| Ten-minute loop with multiple reconnects | Bounded memory and resources; no stale tasks publishing into new streams |
| Small text under maximum blur | Empirical readability assessment; no absolute privacy claim |

## Reference-project findings

`StreamCapture.swift` already uses ScreenCaptureKit, latest-frame retention, a `CVMetalTextureCache`, explicit frame-status inspection, and a lifecycle generation. It is valuable as a local architectural reference. Its current stream filter excludes enumerated own windows, whereas application-level exclusion is a stronger default for a long-lived app that may open new windows.[^15]

`OverlayWindowController.swift` explicitly takes a frame once at show time and keeps it frozen during the fold. The requested sustained privacy behavior therefore cannot be obtained by only replacing its lid-angle input with head yaw. Its shader returns alpha one, including its dark background, and its geometry simulates the folding display. The new app needs flat screen-aligned geometry, live source updates, and alpha-zero clear pixels.[^15]

`SkyLightOperator.swift` loads `/System/Library/PrivateFrameworks/SkyLight.framework` and undocumented `SLS*` functions to place windows above lock-screen spaces. This is out of scope for the supported renderer. Public window behavior and explicit secure-surface limitations provide a maintainable boundary.[^15]

## Sources

[^1]: Apple. [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos). Sample associated with WWDC24; accessed September 13, 2026. Capture configuration, application exclusion, permission startup.
[^2]: Apple, Meng Yang and Drew. [Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/). WWDC22. GPU-backed buffers, dynamic configuration, metadata, queue lifetime/performance.
[^3]: Apple. [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents). Accessed September 13, 2026.
[^4]: Apple. [NSVisualEffectView.BlendingMode](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum). Accessed September 13, 2026.
[^5]: Apple. [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter). Accessed September 13, 2026.
[^6]: Apple. [SCStreamConfiguration.queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth). Accessed September 13, 2026.
[^7]: Apple. [SCContentFilter.pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale) and [contentRect](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect). Accessed September 13, 2026.
[^8]: Apple. [SCFrameStatus.idle](https://developer.apple.com/documentation/screencapturekit/scframestatus/idle). Accessed September 13, 2026; corroborated with installed `SCStream.h` enum documentation.
[^9]: Apple. [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)). Accessed September 13, 2026.
[^10]: Apple. [MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur). Accessed September 13, 2026.
[^11]: Apple. [MTKView](https://developer.apple.com/documentation/metalkit/mtkview) and [enableSetNeedsDisplay](https://developer.apple.com/documentation/metalkit/mtkview/enablesetneedsdisplay). Accessed September 13, 2026.
[^12]: Apple. [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications) and [fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary). Accessed September 13, 2026.
[^13]: Apple. [CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()). Accessed September 13, 2026.
[^14]: Apple installed SDK public headers, read September 13, 2026: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h`, `AppKit.framework/Headers/NSWindow.h`, and `AppKit.framework/Headers/NSVisualEffectView.h` under the same SDK framework root. `SCStream.h` and `NSWindow.h` were also checked under `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/`. Local source for availability, frame statuses, window behavior constraints, and material controls.
[^15]: lqSky7. [iphone-duo-macos-animation](https://github.com/lqSky7/iphone-duo-macos-animation/tree/aa87e34755b88d37dcaae739b1645a504efe0a97). Inspected local checkout `/Users/sharms18/Documents/Projects/iphone-duo-macos-animation` at that commit, September 13, 2026: `Sources/StreamCapture.swift`, `OverlayWindowController.swift`, `FoldShaders.metal`, and `SkyLightOperator.swift`.
[^16]: Apple. [NSWorkspace.sessionDidBecomeActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification) and related environment notification list. Accessed September 13, 2026.
[^17]: Apple. [SCStreamDelegate.stream(_:didStopWithError:)](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream(_:didstopwitherror:)). Accessed September 13, 2026.
