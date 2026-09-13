# Native macOS notch coaching

## Recommendation

Build AirValve's camera coaching as a small native AppKit panel with SwiftUI content, owned by AirValve's existing calibration and wake lifecycle. Open a black surface downward from the physical notch, show a mirrored circular camera preview with a fixed alignment scale beneath it, use red plus a directional cue for off-center and green plus a center marker for aligned, then finish with a short check and collapse. Keep settings available from the menu bar while the main window stays closed.

Use existing notch apps as engineering references. A dedicated AirValve surface avoids depending on another app being installed, avoids competing activity priorities, and can show the camera and lighting guidance without exporting camera frames to a host. The best implementation references are Apple's screen/window APIs and the narrowly scoped MIT packages DynamicNotchKit and Duong Duc Trong's NotchKit. Sapphire and Atoll demonstrate richer behavior but are substantially broader products with copyleft licensing and some private implementation mechanisms. These are architectural recommendations, not claims that any package has already passed AirValve's acceptance tests.

## Product requirements and reference boundaries

The required experience is self-contained in the notch: automatic camera guidance after the established AirPods/wake sequence; an explicit set-center entry point; useful low-light feedback; a visible off-center versus centered distinction; and a smooth confirmation. The existing AirPods removal, screen sleep, Touch ID/system unlock, and calibration rules remain the authority for those actions. The overlay presents their state.

The supplied `Mac-Air-Notch-Recenter-Coach.md` is useful for direction hysteresis, a 450 ms uninterrupted hold, readable copy, and avoiding graphics in the hardware cutout. Its frozen status-chip-only layout, separate main-window preview, and ban on red/green conflict with this product's requested notch preview and colors. Those constraints are reference material, not controlling requirements. The document's iPhone timing analysis is also a secondary description of the recordings; the recordings themselves remain the visual source for animation comparison.[^1]

The hardware camera housing is not a display. The preview, alignment indicator, text, and check must be in live pixels below it or in validated side areas. Apple's safe area APIs identify the unobscured display region; they do not provide an interactive Dynamic Island surface.[^2][^3]

## Project comparison

Repository state and source licenses below were checked on 13 September 2026. Commit hashes pin the examined source, rather than assuming future default-branch code behaves the same way.

| Project | Verified role and source | Useful lesson | Fit for AirValve |
|---|---|---|---|
| [Sapphire](https://github.com/cshariq/Sapphire) | Broad notch app; AGPL-3.0; inspected `e718d72feba6` | Its app delegate builds a transparent nonactivating panel at `.statusBar`, initially ignores mouse input, and observes screen changes. SwiftUI coordinates measured content and shape transitions. | Visual and window-lifecycle reference; avoid importing its broad services or private Spaces machinery.[^4][^5] |
| [Atoll](https://github.com/Ebullioscopic/Atoll) | Established DynamicIsland project; GPL-3.0; inspected `2a8f2ba8efa9` | A reusable panel flag set, activity organization, and source attribution to boring.notch. | Useful production-style reference. Its main panel can become key and main, which should not be copied for passive wake coaching.[^6][^7] |
| [boring.notch](https://github.com/TheBoredTeam/boring.notch) | Broad native utility; GPL-3.0; inspected `85af174f3b38` | Transparent NSPanel with no native shadow; `.fullScreenAuxiliary`, `.stationary`, `.canJoinAllSpaces`, and `.ignoresCycle`; cannot become key/main. | Good minimal window reference, with the same copyleft consideration for copied implementation.[^8] |
| [DynamicNotchKit](https://github.com/mrkai77/DynamicNotchKit) | MIT Swift package; macOS 13+, Swift tools 6.0; inspected `cd0b3e52d537` | Handles real notch dimensions, custom SwiftUI content, compact/expanded states, and notchless display presentation. | Strong lightweight library candidate. Review its `.screenSaver` level and key-window behavior before adopting defaults.[^9][^10][^11] |
| [aishwaryaashok14/notch-kit](https://github.com/aishwaryaashok14/notch-kit) | MIT agent skill plus executable scaffold; package targets macOS 13; inspected `4119779dc4c2` | Small, readable panel/tracking/shape examples. | Learning scaffold rather than a drop-in library. It uses hardcoded fallbacks, `NSScreen.main!`, and separate AppKit frame animation, all needing hardening.[^12][^13] |
| [duongductrong/NotchKit](https://github.com/duongductrong/NotchKit) | MIT Swift library and demo; macOS 14+, Swift tools 5.9; inspected `0d91ac0940f6` | A fixed expanded window with one SwiftUI shape morph; pure geometry; explicit content reveal/hide timing; motion presets. | Closest structural match. Borrow the architecture selectively and verify pointer, accessibility, and capture behavior independently.[^14][^15][^16] |

“Atoll” is ambiguous in search results. This report uses `Ebullioscopic/Atoll`, whose README and notice identify its boring.notch heritage. Other repositories using Atoll for AI-agent monitoring or a separate NotchNook recreation are different products.[^6][^7]

Atoll also publishes [AtollExtensionKit](https://github.com/Ebullioscopic/AtollExtensionKit), which exchanges typed activity and widget descriptors over XPC and requires authorization in the Atoll host. Its documented activity model is useful for status/progress integration, but the inspected README does not establish a native live `AVCaptureVideoPreviewLayer` channel. Using it for this task would introduce an additional app dependency and a camera transport design problem. It is a possible later status integration, not the recommended camera surface.[^17]

## Source reuse and licensing

MIT permits copying and adaptation while retaining the copyright and permission notice in copies or substantial portions. The three MIT references identify Kai Azim, Aishwarya Ashok, and Duong Duc Trong as their copyright holders. If implementation is copied, preserve the applicable original notice and record the exact source and changes in third-party notices.[^18][^19][^20]

GPL v3 has conditions for distributing modified covered works and object code, including licensing the covered work and providing corresponding source through the license's permitted methods. Its private-use permissions should not be confused with unrestricted redistribution. Sapphire's AGPL v3 additionally contains a source-offer requirement for users interacting remotely with a modified network-capable version. Refer to the actual repository license for the specific code being reused.[^21][^22]

A practical engineering choice is to write the small AirValve-specific controller and view from Apple's documented APIs and use MIT code only where it saves meaningful work. This avoids accidentally importing unrelated feature code, asset licensing, or copyleft obligations. This choice is about keeping the dependency and notice inventory clear; it does not imply that studying visible behavior imposes a source license.

Do not treat a repository license as blanket clearance for all bundled artwork. Atoll explicitly separates original and third-party assets, and its notice identifies a fingerprint Lottie animation with its own license. AirValve's check, alignment bars, and shape can be drawn natively, so prerecorded biometric assets are unnecessary.[^23]

Selective reuse also requires checking source comments against the API. Duong's panel helper calls `.readOnly` when asked to exclude the window from capture, but Apple defines that value as allowing another process to read the content. Apple also says the legacy `.none` value must not be used to promise capture exclusion. Do not copy either pattern as a privacy guarantee; stopping or hiding the camera preview is the dependable application behavior when it should not be visible.[^15][^40][^41]

## Window, hardware geometry, and Spaces

### Native host

Use a borderless `NSPanel` created with `.nonactivatingPanel`, a transparent background, `isOpaque = false`, `hasShadow = false`, `hidesOnDeactivate = false`, and `isMovable = false`. Keep `canBecomeMain = false`. A passive coach can also keep `canBecomeKey = false`; if later controls require keyboard input, explicitly manage that interaction rather than making each automatic appearance an activation event. Apple's nonactivating style is specifically for a panel that does not activate its owning app.[^24]

Prefer `.statusBar` as the initial level. DynamicNotchKit uses `.screenSaver`; boring.notch and Atoll use `.mainMenu + 3`; Sapphire and Duong's kit use `.statusBar`. These are observed implementation choices, not a requirement to copy the highest value. AirValve needs a visible post-unlock overlay, not a window above authentication or security UI.[^5][^8][^10][^15]

Make the AppKit window large enough for the fully expanded design, anchor its top to the display top, and animate the visible SwiftUI shape within it. Avoid having `NSAnimationContext` resize the same surface while SwiftUI runs a separate spring. Duong's implementation documents precisely this separation; its motion code also hides outgoing content earlier than incoming content appears.[^15][^16]

The larger transparent window creates a pointer responsibility. `NSView.hitTest` controls routing inside the view hierarchy; do not assume that returning nil alone guarantees delivery to another application's window. Use `ignoresMouseEvents = true` for a passive overlay. If clickable controls are needed, update window mouse handling based on the visible interactive region, then verify that clicks outside the drawn surface reach the app underneath. Prefer a deliberately small set of controls, with advanced controls in settings. The exact through-window behavior requires an actual UI test.

### Screen selection and frame calculation

Choose the active built-in notched display where possible, not whichever screen contains the currently focused window. `NSScreen.main` is the screen with keyboard focus and can be an external monitor. Preserve a display identifier for the lifetime of one coaching session and recompute when display configuration changes.[^25]

For a display with valid auxiliary areas, use their global coordinates to determine the cutout:

```text
cutoutMinX = leftAuxiliaryArea.maxX
cutoutMaxX = rightAuxiliaryArea.minX
cutoutWidth = cutoutMaxX - cutoutMinX
cutoutHeight = safeAreaInsets.top
panelTop = screen.frame.maxY
panelCenterX = (cutoutMinX + cutoutMaxX) / 2
panelOriginY = panelTop - expandedPanelHeight
```

This avoids assuming the screen origin is zero, or that a MacBook Pro dimension applies to an Air. Apple's auxiliary rectangles use global screen coordinates. Validate finite positive sizes and bounds before using them; fall back deliberately if the areas are unavailable.[^3]

Reserve `cutoutHeight` at the top of the expanded view and place the circular preview entirely below that reserve. The hardware silhouette and rendered shell are different geometries: the shell can be wider and deeper while the cutout remains a fixed non-content region. Do not put the centered marker, success check, or text in the physical cutout.

On an external display or in clamshell mode, use a small top-center floating surface below the visible menu-bar boundary. A fake cutout should not obscure normal menu items. Hide or relocate the surface if the selected display disappears. Observe `NSApplication.didChangeScreenParametersNotification` and recalculate frame, safe-area reserve, and backing-scale alignment.

### Full screen and Stage Manager

Start with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`, and `.ignoresCycle`, which are shared by several inspected implementations. `.canJoinAllSpaces` concerns Spaces; `.fullScreenAuxiliary` concerns full-screen placement. They do not grant the ability to appear on the secure login screen.[^26][^27]

On macOS 13+, `.canJoinAllApplications` describes floating overlays that can join other apps' full-screen spaces when eligible, without participating in Stage Manager's layout. Apple makes it mutually exclusive with `.primary` and `.auxiliary`; do not set all three. Its eligibility wording also means API flags alone are not a universal full-screen visibility guarantee.[^28]

For AirValve, start presentation when the existing controller has established a valid post-unlock camera session. A screen-wake notification is not proof that Touch ID authentication has finished. Avoid transplanting Atoll's `CGSSpace` mechanism or Sapphire's lock-screen services into the coach. The reported experience takes place after normal Mac unlock, so private lock-screen rendering is unnecessary.

## Camera and guidance pipeline

Reuse the existing capture session and calibration result. Add an `AVCaptureVideoPreviewLayer` attached to that session and mask its host view to a circle. The preview layer is a native camera rendering layer; it also supplies coordinate conversions that consider its bounds and `videoGravity`.[^29][^30]

Keep capture/session work and Vision analysis off the main thread. Publish small state snapshots on the main actor: session ID, observed timestamp, face position error, direction, framing status, lighting status, hold progress, and final calibration result. Do not send or retain image frames just to drive UI animation. Set `alwaysDiscardsLateVideoFrames = true` so analysis does not accumulate obsolete frames behind a blocked callback.[^31]

### Coordinate agreement

The preview is a mirror for the person positioning themselves. Its left/right coaching must agree with the image on screen. Convert Vision's normalized, bottom-left geometry into the oriented preview coordinate system, apply mirroring exactly once, and account for the circular crop's aspect-fill transform. Apple's preview conversion APIs work with camera-device or metadata coordinates; a Vision rectangle must be mapped into the appropriate input coordinate system first.[^29][^30]

A useful behavioral test is to feed a synthetic face left of center and ensure the visible cue points toward the empty right side of the mirrored preview. Repeat for right, up, down, diagonal movement, and a portrait/landscape source. Do not use a face-following crop that keeps the person's face visually centered while simultaneously reporting that it is off-center: the viewport and reference marker should remain fixed.

Use an ideal framing box as the normalization denominator, rather than the current detected face width, so moving nearer the camera does not silently change the centering tolerance. Distinguish position from orientation and distance. A centered face turned sideways is not the same as a frontal face positioned left of the target.

### Honest failure messages

| Observation | Appropriate cue | Suppressed behavior |
|---|---|---|
| Camera starting | “Starting camera” with restrained static/short progress feedback | Off-center arrows and success |
| No credible face | “Find me in the frame” | Direction inferred from a stale face |
| Sustained low measured exposure | “More light needed” or “Move into the light” | Success while the capture is unusable |
| Wrong orientation | “Face forward” | Misleading lateral nudge |
| Face too large/small | “A little farther” / “A little closer” | Changing position thresholds to disguise scale error |
| Valid off-center face | Red marker plus arrow and “A bit left/right/up/down” | Color-only guidance |
| Valid centered face | Green center marker, hold progress | Success before calibration accepts the sample |
| Permission unavailable or camera busy | Specific message and a route to retry/settings | A generic scan animation that never resolves |

Vision's `faceCaptureQuality` combines lighting, blur, positioning, and other capture attributes, and is intended to compare captures of the same face. It is not a calibrated darkness detector. Vision's observation confidence is likewise not a universal lighting metric; Apple notes that a confidence of 1 can also mean the observation does not assign meaning to confidence.[^32][^33][^34]

Therefore, low-light copy should be driven by measured camera-buffer luminance with smoothing and hysteresis, preferably emphasizing the face region once available. Treat a fixed luma cutoff as an initial heuristic that requires tests with backlighting, dark backgrounds, skin tones, glasses, and automatic exposure. Do not make a no-face condition alone imply insufficient light. A whole-frame average can be fooled by a bright window behind an underexposed face.

Camera authorization continues through macOS's normal per-app permission mechanism. The application requires a camera purpose string and the applicable camera entitlement configuration. The overlay should explain a denied state and return control; it should never remain in a simulated scanning state after capture fails.[^35]

## State and motion contract

Use one semantic state machine rather than separate view timers that can race with the calibration controller:

```text
hidden → starting → seeking / needsLight / coaching → holding
holding → success → collapsing → hidden
holding → coaching / needsLight / seeking      (hold reset)
any active state → cancelled / failed → hidden or actionable retry
```

The following values are design starting points, combining the supplied reference's short hold and check with the requested expanded preview. They are not Apple-mandated durations.

| Event | Initial design target | Rule |
|---|---|---|
| Open surface | About 240–320 ms, critically damped or near it | One shape animation, fixed top anchor |
| Reveal preview and text | About 160–200 ms, after a short opening head start | Fade/clip content without scaling the camera image |
| Nudge update | About 160–220 ms | Smooth marker movement; crossfade words and arrows |
| Direction change | Dominant-axis ratio 1.35 and 180 ms minimum dwell as an initial heuristic | Reject diagonal jitter |
| Center hold | 450 ms continuous valid input | Linear progress; immediate reset on invalid input |
| Success | Check settles in roughly 220 ms, readable around 500 ms | Emit only after the existing calibration transaction succeeds |
| Collapse | Around 280–320 ms, little or no overshoot | Fade outgoing content before clipping tight |

The hold needs observed frames throughout its duration. An async sleep started from one good frame is insufficient: the camera may stop, the face may disappear, or a new session may begin while the timer is pending. At completion, require matching session identity, fresh observations, valid framing, suitable quality, and a still-active calibration transaction. Cancellation and completion should be idempotent. An initially centered face should enter holding directly; requiring an off-center movement first is an avoidable dead end.

The attached sample state machine is illustrative and does not fully implement its prose contract: it leaves an initially centered idle state unchanged, and a dwell timer alone cannot establish fresh input. Preserve the design intent while implementing the state transitions against the real app lifecycle.[^1]

Success should acknowledge the accepted sample once. Do not set the main app's “calibrated” state merely because the animation reached a checkmark. If camera and AirPods samples are both required, the confirmation must wait for the authoritative combined result. Red/green communicates framing quality, not identity verification or macOS authentication.

## Accessibility and responsiveness

Pair every color state with text and geometry: red plus an arrow, green plus a center tick/check, amber plus a light symbol. Keep the preview's alignment reference stationary. Make labels large enough to read below the notch without leaning toward the display, and give actionable buttons meaningful accessibility labels.

Read SwiftUI's `accessibilityReduceMotion` and update the behavior if the setting changes during a session. With Reduce Motion enabled, replace size/scale springs with short crossfades and steady progress; remove decorative pulsing, parallax, and orbiting scans. Preserve the success and failure information. Apple recommends changing or removing problematic motion while retaining meaningful feedback.[^36][^37]

If the controller reads AppKit accessibility preferences, observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on the workspace's own notification center. Apple explicitly notes that a different notification center will not deliver it.[^38]

Camera display should not depend on Vision completing every frame. Keep image rendering, tracking updates, and semantic announcements separate; announcing every frame or constantly retriggering an implicit animation will hurt accessibility and perceived steadiness. Apple’s motion guidance favors brief, precise, interruptible feedback.[^39]

## Validation that remains necessary

Source inspection supports the architecture, but does not establish behavior on every MacBook Air, display arrangement, or full-screen configuration. Finish with these practical checks:

| Area | Evidence needed |
|---|---|
| Geometry | Notched Air at current scaling; nonzero screen origin; external display; clamshell or unavailable built-in display |
| Focus | Automatic opening leaves the frontmost app active; typing still goes there; clear window areas do not intercept clicks |
| System modes | Normal desktop, fullscreen, hidden menu bar, Spaces switch, Stage Manager; no overlay on the secure lock screen |
| Camera | First permission, already authorized, denied, busy/unavailable, interrupted, resumed; camera stops when its session ends |
| Tracking | Initially centered; four directions; diagonal jitter; drift during hold; lost face; stale observation; multiple faces |
| Lighting | Low exposure, recovery into light, backlit face, dark background, automatic exposure change; no false diagnosis from confidence alone |
| Lifecycle | Set center, established AirPods removal/reinsert/wake flow, repeated trigger, cancellation, app quit, settings open/close |
| Animation | Video or frame review of open, guidance, success and collapse; no double resize, menu overlap, camera stretch, or late callback |
| Accessibility | Reduce Motion at launch and changed live; state understandable without red/green; usable settings route |
| Privacy | No camera images written to disk or network for coaching; no new permission requested by a decorative effect |

## Sources

All web sources were accessed on 13 September 2026. Repository links below are pinned to the inspected commit where implementation or licensing matters. Apple pages are living documentation.

[^1]: Supplied local document, [Mac-Air-Notch-Recenter-Coach.md](/Users/sharms18/Downloads/Mac-Air-Notch-Recenter-Coach.md), sections 2, 6, 10, 15 and 16; private attachment. Used as design reference, not as overriding instructions.
[^2]: Apple, [NSScreen.safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets).
[^3]: Apple, [NSScreen.auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc).
[^4]: cshariq, [Sapphire repository](https://github.com/cshariq/Sapphire).
[^5]: cshariq, [Sapphire AppDelegate.swift](https://github.com/cshariq/Sapphire/blob/e718d72feba61538a61ffc14e3abc32a9b4e35b9/Sapphire/App/AppDelegate.swift) and [NotchController.swift](https://github.com/cshariq/Sapphire/blob/e718d72feba61538a61ffc14e3abc32a9b4e35b9/Sapphire/Notch/NotchController.swift).
[^6]: Ebullioscopic, [Atoll README](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/ReadMe.md).
[^7]: Ebullioscopic, [DynamicIslandWindow.swift](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/DynamicIsland/components/Notch/DynamicIslandWindow.swift) and [NOTICE](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/NOTICE).
[^8]: TheBoredTeam, [BoringNotchWindow.swift](https://github.com/TheBoredTeam/boring.notch/blob/85af174f3b3894996152c5402f6569a987d86694/boringNotch/components/Notch/BoringNotchWindow.swift) and [repository license](https://github.com/TheBoredTeam/boring.notch/blob/85af174f3b3894996152c5402f6569a987d86694/LICENSE).
[^9]: Kai Azim, [DynamicNotchKit Package.swift](https://github.com/mrkai77/DynamicNotchKit/blob/cd0b3e52d537db115ad3a9d89601f20e0bee8d27/Package.swift) and [README](https://github.com/mrkai77/DynamicNotchKit).
[^10]: Kai Azim, [DynamicNotchPanel.swift](https://github.com/mrkai77/DynamicNotchKit/blob/cd0b3e52d537db115ad3a9d89601f20e0bee8d27/Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift).
[^11]: Kai Azim, [NSScreen+Extensions.swift](https://github.com/mrkai77/DynamicNotchKit/blob/cd0b3e52d537db115ad3a9d89601f20e0bee8d27/Sources/DynamicNotchKit/Utility/NSScreen%2BExtensions.swift).
[^12]: Aishwarya Ashok, [notch-kit Package.swift](https://github.com/aishwaryaashok14/notch-kit/blob/4119779dc4c211c9584af7f97554c4e17bc91891/Package.swift).
[^13]: Aishwarya Ashok, [NotchWindow.swift](https://github.com/aishwaryaashok14/notch-kit/blob/4119779dc4c211c9584af7f97554c4e17bc91891/NotchKit/NotchWindow.swift) and [NotchPanel.swift](https://github.com/aishwaryaashok14/notch-kit/blob/4119779dc4c211c9584af7f97554c4e17bc91891/NotchKit/NotchPanel.swift).
[^14]: Duong Duc Trong, [NotchKit Package.swift](https://github.com/duongductrong/NotchKit/blob/0d91ac0940f679bf306315fa5ba590e11e46cc3c/Package.swift) and [NotchGeometry.swift](https://github.com/duongductrong/NotchKit/blob/0d91ac0940f679bf306315fa5ba590e11e46cc3c/Sources/NotchKit/NotchGeometry.swift).
[^15]: Duong Duc Trong, [NotchPanel.swift](https://github.com/duongductrong/NotchKit/blob/0d91ac0940f679bf306315fa5ba590e11e46cc3c/Sources/NotchKit/NotchPanel.swift).
[^16]: Duong Duc Trong, [NotchMotion.swift](https://github.com/duongductrong/NotchKit/blob/0d91ac0940f679bf306315fa5ba590e11e46cc3c/Sources/NotchKit/NotchMotion.swift).
[^17]: Ebullioscopic, [AtollExtensionKit README](https://github.com/Ebullioscopic/AtollExtensionKit).
[^18]: Kai Azim, [DynamicNotchKit MIT license](https://github.com/mrkai77/DynamicNotchKit/blob/cd0b3e52d537db115ad3a9d89601f20e0bee8d27/LICENSE).
[^19]: Aishwarya Ashok, [notch-kit MIT license](https://github.com/aishwaryaashok14/notch-kit/blob/4119779dc4c211c9584af7f97554c4e17bc91891/LICENSE).
[^20]: Duong Duc Trong, [NotchKit MIT license](https://github.com/duongductrong/NotchKit/blob/0d91ac0940f679bf306315fa5ba590e11e46cc3c/LICENSE); Open Source Initiative, [MIT license](https://opensource.org/license/mit).
[^21]: Atoll / Free Software Foundation, [GPL v3 license](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/LICENSE), sections 2, 5 and 6.
[^22]: Sapphire / Free Software Foundation, [AGPL v3 license](https://github.com/cshariq/Sapphire/blob/e718d72feba61538a61ffc14e3abc32a9b4e35b9/LICENSE), sections 2, 5, 6 and 13.
[^23]: Ebullioscopic, [COPYRIGHT_ASSETS](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/COPYRIGHT_ASSETS) and [NOTICE](https://github.com/Ebullioscopic/Atoll/blob/2a8f2ba8efa93ef76b641e41e4457ee63709a1bc/NOTICE).
[^24]: Apple, [NSWindow.StyleMask.nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel).
[^25]: Apple, [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen).
[^26]: Apple, [NSWindow.CollectionBehavior.canJoinAllSpaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces).
[^27]: Apple, [NSWindow.CollectionBehavior.fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary).
[^28]: Apple, [NSWindow.CollectionBehavior.canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications), available on macOS 13 and later.
[^29]: Apple, [AVCaptureVideoPreviewLayer](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer).
[^30]: Apple, [layerPointConverted(fromCaptureDevicePoint:)](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/layerpointconverted%28fromcapturedevicepoint%3A%29).
[^31]: Apple, [AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes).
[^32]: Apple, [VNFaceObservation.faceCaptureQuality](https://developer.apple.com/documentation/vision/vnfaceobservation/facecapturequality-bjg5).
[^33]: Apple, [Selecting a selfie based on capture quality](https://developer.apple.com/documentation/vision/selecting-a-selfie-based-on-capture-quality).
[^34]: Apple, [VNObservation.confidence](https://developer.apple.com/documentation/vision/vnobservation/confidence).
[^35]: Apple, [Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media).
[^36]: Apple, [EnvironmentValues.accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).
[^37]: Apple, [Reduced Motion evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria).
[^38]: Apple, [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification).
[^39]: Apple, [Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion).
[^40]: Apple, [NSWindow.SharingType.readOnly](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/readonly).
[^41]: Apple, [NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).
