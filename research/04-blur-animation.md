# Directional blur and animation for AirVeil

## Recommendation

Use an original Metal compositor over a fresh, self-excluded ScreenCaptureKit display image. Produce a spatial Gaussian blur, then reveal that blurred image through a feathered mask on the side opposite the calibrated head turn. Keep image processing separate from head-pose smoothing: only the mask and blur-selection parameters animate over time; image pixels never accumulate from earlier rendered frames.

The proposed baseline is a small bank of full-resolution MPS Gaussian images, reused until a new captured frame arrives, with continuous interpolation between levels. This is a practical engineering recommendation, not an Apple-prescribed architecture or a measured performance result. Benchmark it on the target Mac before promising a refresh rate. A single full-resolution Gaussian image plus smoothly changing opacity is an acceptable first renderer, but it should be recognized as a visual crossfade rather than a genuinely changing Gaussian radius.

Apple supplies a fast approximate Gaussian through `MPSImageGaussianBlur`; it is suitable for normal image processing, although Apple expressly distinguishes it from an analytically exact Gaussian. Its `sigma` is read-only after creation, so do not plan to mutate one kernel's radius every frame. Cache kernels and textures instead.[^1][^2]

Software changes the pixels that all viewers see. It cannot create different viewing angles for the owner and a nearby person. Blur also leaves large shapes and possibly large lettering recognizable. An optional opaque concealment mode should use the same smooth directional mask and become fully opaque at the selected full-effect angle. This is an implication of the proposed rendering operation, not a measured confidentiality guarantee.

## What the macTilt reference contributes

The local `Sources/FoldShaders.metal` was inspected read-only. Its effect combines hinge-relative perspective, spatial blur whose radius increases with fold progression, depth-dependent weighting, subtle darkening, and a final closure. Its blur samples the current texture rather than averaging previous frames. Its comments identify excessive mip levels as a prior source of large pixel blocks, and its current shader bounds mip selection and distributes samples spatially.[^3]

The useful design principle is coupling a continuous physical input to several restrained visual properties. AirVeil should borrow that principle, not the geometry: the desktop itself should remain stationary so text and pointer targets retain their positions. Head yaw should control opposite-side softness and concealment, without tilting the underlying work surface. No macTilt source should be copied until its license is confirmed; the equations below are a new proposal.

The reference's written statements about “100%” smoothness or absence of pixelation are comments, not test evidence. AirVeil must render its own test patterns at native size. A sparse disc kernel can still expose ringing or duplicated high-contrast detail; using a Gaussian implementation reduces the need to tune arbitrary tap patterns.

## Input transfer and directional continuity

Define calibrated yaw `q` in degrees, with **positive meaning a physical left turn**, after validating the hardware sign or applying the direction-inversion setting. Normalize yaw around the calibrated reference using wrapped angular differences; do not directly subtract arbitrary Euler angles across a ±180° discontinuity. Motion validity, freshness and calibration belong to the motion service and must be checked before the following transfer function runs.

For provisional onset `d = 8°` and full-effect angle `f = 32°`, define:

```text
h(v) = t*t*(3 - 2*t), where t = clamp((v-d)/(f-d), 0, 1)
targetRight = h(max(q, 0))
targetLeft  = h(max(-q, 0))
```

These angles are initial UX choices, not Apple sensor specifications. Enforce `0 <= d < f` in settings. Clamp or reject nonfinite values; a NaN must not reach the shader. An 8° dead zone tolerates small head adjustments, while the cubic curve makes onset and saturation gradual. Test its usefulness with real seated head turns and let the person adjust it.

Smooth `left` and `right` independently rather than smoothing an absolute angle and abruptly changing a sign bit. At a direction reversal, the previous side releases while the new side grows; a brief partial effect on both sides is coherent, whereas teleporting a full-strength mask across the display is visually disruptive.

For each channel `y` with target `u`:

```text
tau = 0.070 seconds when u > y, otherwise 0.140 seconds
a = 1 - exp(-dt / tau)
y = clamp(y + a*(u-y), 0, 1)
```

This is the exact first-order response for a constant target during the time step. It is independent of the nominal frame rate, so 30, 60 and 120 Hz converge to the same state at equal elapsed times when input changes are aligned. With these provisional constants, the effect reaches 90% of a rising step after about 161 ms and releases 90% after about 322 ms; these are mathematical predictions, not measured sensor-to-display latency. Do not add a second long filter in the motion service, because the resulting delay can make concealment feel late.

Use elapsed monotonic time. Handle suspension and invalid time intervals explicitly: after wake or a stale sensor stream, enter the app's declared safety state and require valid recalibration instead of replaying a large old animation step. A critically damped spring is possible later, but exponential smoothing has no overshoot and is easier to audit for a privacy effect.

## Spatial mask and original compositor

Let `x` be normalized display coordinates from the physical left edge to the right edge. A fixed half-screen mask gives predictable behavior:

```text
mRight(x) = smoothstep(0.5 - w/2, 0.5 + w/2, x)
mLeft(x) = 1 - mRight(x)
coverage = clamp(left*mLeft(x) + right*mRight(x), 0, 1)
```

Start with feather width `w = 0.12` of the display width; expose an appropriate range such as 0.02–0.30. At maximum right-side coverage, the leftmost 44% is unaffected, the rightmost 44% is fully covered, and the middle 12% transitions. That transition intentionally remains partly readable. Do not label it fully concealed. A stricter mode can move the boundary slightly toward the owner-facing side or reduce the feather width, but should show that extent in the preview.

Keep the final overlay fully transparent outside its mask instead of displaying a copied sharp screenshot there. This allows the unmodified desktop, pointer and animations to remain native and eliminates capture latency on the unaffected region. A partially covered region blends a blurred recent capture with the live underlying desktop, so very fast scrolling can show transient disagreement. This cannot be eliminated by numerical smoothing; it should be checked with moving synthetic text and compared against opaque concealment.

For varying blur, compute full-resolution source-derived levels `B0 = source`, `B1`, `B2`, `B3` at provisional sigmas of 0, 6, 16 and 32 points converted to source pixels. Compute a requested sigma from coverage, for example `sigma = sigmaMax * sqrt(coverage)`, and interpolate the two adjacent levels by variance:

```text
k = clamp((sigma*sigma - sigmaLow*sigmaLow) /
          (sigmaHigh*sigmaHigh - sigmaLow*sigmaLow), 0, 1)
blurColor = mix(BLow(uv), BHigh(uv), k)
alpha = coverage
output = float4(blurColor * alpha, alpha)
```

Interpolating two Gaussian images is a continuous approximation, not the exact Gaussian at intermediate sigma. It can be judged visually without misrepresenting the mathematics. The zero-coverage branch must emit transparent black, not the captured source. Full coverage must reach alpha one so the original sharp background cannot leak through at the outer protected side. Use correct premultiplied output throughout the final overlay path; Apple documents the relevant premultiplication and compositing conventions.[^4]

In the stronger concealment mode, mix `blurColor` toward an opaque neutral color as coverage approaches one, for example with `smoothstep(0.65, 1, coverage)`. At coverage one the result contains no source color. Emergency concealment should bypass the directional feather and output opaque neutral color across the intended displays, subject to documented system-window limitations. Keep a reachable pause/menu control.

Gaussian filters operate on the opaque source before any spatial alpha is introduced. Blurring an already transparent mask risks dark or colored fringes and can mix values with the wrong alpha convention. Apple notes that most MPS image kernels expect non-premultiplied or opaque image data.[^4] Use clamp-to-edge for Gaussian input and final texture sampling; zero-padding can create an artificial dark border because out-of-bounds samples are otherwise zeros.[^5]

## Rendering choices and resource bounds

| Candidate | Benefit | Limitation | Decision |
|---|---|---|---|
| One MPS Gaussian plus mask opacity | Smallest implementation; continuous reveal | Radius is constant; transitional source remains visible | Useful first increment |
| Three cached full-resolution MPS levels | Continuous adjustable softness; no deliberate resolution reduction | Several full-screen textures and passes | Preferred quality baseline; benchmark |
| Original separable compute Gaussian | Explicit weights, control of passes and precision | More shader and edge-condition code | Fallback when MPS behavior is unsuitable |
| Sparse large-radius disc sampling | One compositor pass | High-contrast duplicate taps/rings and quality tuning | Avoid as initial quality baseline |
| Mipmap-only blur | Very low work | Excessive levels can look blocky and lose fine gradients | Insufficient alone |
| Temporal accumulation | Smooth-looking still images | Moving content trails and retained sensitive pixels | Exclude |

Blur sigmas are in texture pixels; UI strength should be expressed in points and multiplied by the actual per-display scale. Do not assume all screens are 2× Retina or have the same logical width. Maintain separate source dimensions, output drawable dimensions and coordinate transforms for each display.

Build the MPS kernels once per strength/scale configuration. Recompute their output only when a new complete source frame arrives. The mask may continue rendering from the latest completed blur bank when pose changes between captures. Do not overwrite an image bank the GPU is still sampling: encode blur and composite in the same ordered command buffer, or use explicit ownership of a bounded number of banks. Avoid an unbounded work queue.

The memory budget must be explicit. At 3024×1964 BGRA8, one texture is about 22.7 MiB; three blur outputs alone consume about 68 MiB. At 6016×3384, one is about 77.7 MiB and three outputs about 233 MiB. Capture buffers, intermediate MPS storage, drawable buffers and multiple in-flight banks add to those arithmetic lower bounds. Therefore, “full resolution” is a quality choice with a real multi-display cost, not a free default. If reducing resolution becomes necessary, downsample only the already-soft branch, use proper low-pass filtering and linear reconstruction, and keep the clear region native.

Map IOSurface-backed captured images through `CVMetalTextureCache`. Retain the `CVMetalTexture` wrapper until GPU completion; Apple specifically warns that the underlying API does not retain it automatically for this purpose.[^6] A texture reference surviving in Swift is not sufficient evidence if its Core Video wrapper has been released.

## Timing, capture and frame freshness

The easiest macOS baseline is `MTKView`'s built-in drawing loop with a requested 60 fps. Apple states that the view chooses a supported cadence close to the request and that the app should choose a rate it can sustain.[^7] Do not treat that requested rate as a measured outcome.

For a custom loop on the macOS 14 deployment target, `NSView.displayLink(target:selector:)` returns a `CADisplayLink` synchronized to the display containing the view. It stops callbacks when the view is hidden or not on a display. Apple's macOS Sonoma release notes and WWDC23 session explicitly introduce this support.[^8][^9] This supersedes an older Apple Metal sample that says CADisplayLink is unavailable on macOS; that older platform statement should not guide the new app.[^10]

Render with actual elapsed time and never assume a fixed 1/60 second step. Requesting 120 fps cannot manufacture new 120 Hz screen-capture or head-motion data. A display-synchronized loop can interpolate mask values between source samples, but image freshness remains limited by capture delivery and GPU work. Avoid a repeating `Timer` as the visual clock.

Use a small ScreenCaptureKit frame queue, initially its documented default of three. Apple allows higher depth but says not to exceed eight; larger queues consume more memory.[^11] The capture callback should publish only the newest usable frame, with no backlog of older pending frames. Apple's capture sample checks `.complete` frame status before processing image data.[^12]

Idle capture delivery is not necessarily failure: an unchanged desktop may produce no new usable image while the retained image remains correct. Distinguish a motion timeout, a capture error/stop event, an incomplete frame, and a static source. Test failover by an actual stream failure, not just by waiting on a motionless desktop. Never silently reuse an old image after the source stream has reported failure while continuing to claim active protection.

Exclude AirVeil's entire application from the capture filter, including overlay windows and synthetic preview. Otherwise the overlay can enter its own source and recursively blur/darken on every capture. No previous output texture should be sampled as input to the next source blur. These are implementation invariants, and a moving test scene should verify them.

## Preview and accessibility

Use a synthetic sample desktop with ordinary paragraphs, a large heading, colored content blocks and a moving object. It should use the same rendering/math parameters as the desktop effect, so it can reveal side inversion, weak maximum blur and ringing without requesting screen recording. Clearly label the preview as simulated when the slider rather than AirPods drives it. Show “Turn left → right side obscured” with a live angle indicator and independent motion-connected/calibrated state.

Keep labels and settings controls outside the effect; blur only the demonstration surface. Test controls at increased text size, keyboard-only navigation and both appearances. Distinguish active, paused and unavailable with words in addition to color.

Read Reduce Motion and avoid hinge-like perspective, overshooting springs and gratuitous camera movement. Apple specifically recommends avoiding large animations, especially simulated 3D, when this setting is enabled.[^13] A short monotonic opacity change preserves understandable feedback; concealment should remain functional. Reduce Transparency can use the opaque concealment treatment rather than preserving translucent materials for decoration.

## Verification required before completion

1. **Direction:** a calibrated physical left turn activates the right side and vice versa. Confirm using live AirPods, not just a slider or yaw sign assumption.
2. **Neutral:** the desktop is unchanged inside the dead zone; synthetic offscreen rendering verifies zero alpha across the output when both channels are zero.
3. **Maximum:** the protected outer region reaches alpha one at full strength. In opaque mode, changes in source pixels produce no changes there.
4. **Time invariance:** equivalent timestamped inputs at 30, 60 and 120 Hz give matching channel values at aligned elapsed times. Reject NaN, infinity, reversed thresholds and invalid time steps.
5. **Transitions:** neutral→left→neutral→right and abrupt reversal produce no mask jump, overshoot, flicker or unexpected transparent flash.
6. **Visual quality:** native-resolution synthetic small text, large lettering, a checkerboard and black/white edges expose pixelation, haloing, banding and insufficient obscuration. Validate both 1× and 2× backing scale and a display with a nonzero global origin.
7. **Freshness:** scroll and animate synthetic content behind the overlay for at least a minute. No recursive darkening or retained-frame trails; explicitly distinguish expected capture latency from temporal accumulation.
8. **Performance:** measure command-buffer GPU duration after completion using `gpuEndTime - gpuStartTime`, plus presentation cadence and capture-to-render age. Apple documents that GPU timestamps remain zero until completion.[^14] Proposed initial target: sustained 60 fps on the test Mac with 95th-percentile GPU work below 8 ms on its primary display; this is an acceptance target, not an existing benchmark.
9. **Lifecycle:** repeat enable/disable, screen changes, sleep/wake, sensor disconnect and capture revocation. Check that in-flight frames and textures release, old sessions cannot reactivate, and the UI reports the actual state.
10. **Escape:** Pause and Quit must remove overlays promptly. Failover concealment must not trap input or make the only exit unreadable.

Research supports the design's feasibility; it does not prove hardware cadence, visual quality, system-wide window coverage or a confidentiality level. Those are runtime acceptance gates.

## Sources

All live Apple documentation below was consulted on September 13, 2026. Undated documentation may change. No third-party shader code is incorporated.

[^1]: Apple. [MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur). Official API documentation; approximate Gaussian behavior and intended precision.
[^2]: Apple. [sigma](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur/sigma) and [init(device:sigma:)](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur/init(device:sigma:)). Official API documentation; read-only sigma and standard-deviation parameter.
[^3]: Local reference file: `/Users/sharms18/Documents/Projects/iphone-duo-macos-animation/Sources/FoldShaders.metal`, inspected September 13, 2026. Architectural/visual comparison only; license and current upstream equivalence unverified.
[^4]: Apple. [MPSAlphaType](https://developer.apple.com/documentation/metalperformanceshaders/mpsalphatype) and [Compositing images with alpha blending](https://developer.apple.com/documentation/accelerate/compositing-images-with-alpha-blending). Official API/article documentation; opaque input and alpha conventions.
[^5]: Apple. [MPSImageEdgeMode](https://developer.apple.com/documentation/metalperformanceshaders/mpsimageedgemode). Official API documentation; clamp and zero-padding behavior.
[^6]: Apple. [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)). Official API documentation; texture mapping and wrapper lifetime requirement.
[^7]: Apple. [MTKView.preferredFramesPerSecond](https://developer.apple.com/documentation/metalkit/mtkview/preferredframespersecond). Official API documentation; sustainable and supported draw cadence.
[^8]: Apple. [NSView.displayLink(target:selector:)](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)) and [AppKit Release Notes for macOS Sonoma 14](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14). Official documentation; macOS 14 CADisplayLink availability and display tracking.
[^9]: Apple. [What's new in AppKit](https://developer.apple.com/videos/play/wwdc2023/10054/), WWDC23, display-link discussion around 12:00. Primary platform introduction.
[^10]: Apple. [Creating a custom Metal view](https://developer.apple.com/documentation/metal/creating-a-custom-metal-view). Official older sample; useful rendering-loop discussion but superseded macOS availability statement.
[^11]: Apple. [SCStreamConfiguration.queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth). Official API documentation; default and upper queue bounds.
[^12]: Apple. [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos). Official sample; complete-frame check and IOSurface-backed pixel buffers.
[^13]: Apple. [NSWorkspace.accessibilityDisplayShouldReduceMotion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion). Official API documentation; reduced-motion behavior.
[^14]: Apple. [MTLCommandBuffer.gpuStartTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime). Official API documentation; completion-time GPU measurement.
