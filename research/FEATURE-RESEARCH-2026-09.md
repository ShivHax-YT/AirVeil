# AirVeil feature opportunities

## Recommendation

AirVeil’s next release should make its behavior easier to understand, reduce the permissions needed for useful protection, and give people predictable control over interruptions. The strongest new candidates are **Tracking health**, **Solid veil without desktop capture**, and **Comfortable controls**. A second group—application pause rules, energy-aware operation, camera recovery guidance, and controlled software updates—would make the app easier to keep installed and use every day.

These are proposed capabilities, not implemented features. The assessment uses the 0.13.0 build 17 source baseline and primary sources reviewed on September 14, 2026. Rankings and relative effort are engineering and product judgments, not measured customer demand, delivery estimates, or guarantees of hardware behavior. The intended platform remains Apple silicon on macOS 14 or later. Features relying on newer APIs need availability checks and older-system fallbacks.

The central product opportunity is a quiet, local utility whose decisions are understandable. AirVeil should avoid escalating a temporary interruption into repeated camera activity or a misleading claim of protection. It should also distinguish visual obscuration from authentication: a screen overlay does not change a display’s viewing angle, stop every recording path, identify its wearer, or replace the Mac’s lock screen.

## Current baseline and earlier proposals

The released app already includes opposite-side head-driven blur, opaque appearance, independent left/right onset angles, selected displays, click blocking, a pause shortcut, optional camera centering, removal/presence behavior, brightness restoration, first-launch Settings onboarding, a persistent notch tour, and automatic low-light illumination. Source inspection confirms that selecting the current opaque appearance still uses the desktop-capture startup path; a mode that never captures the desktop would be a substantive addition.[^1]

The earlier [next-features memo](NEXT-FEATURES.md) already proposed setup rehearsal, named workspace profiles, timed pause, launch at login, and Shortcuts actions. Those remain useful backlog items. They are separated here from newly identified opportunities rather than presented as new discoveries.[^2]

| Rank | New proposal | Everyday value | Relative effort | Added data access |
|---|---|---|---|---|
| 1 | Tracking health and a local explanation history | Understand why AirVeil paused and how to recover | Medium | None for a summary of existing state |
| 2 | Solid veil without desktop capture | Useful visual cover with fewer permissions | Medium–large | Removes desktop capture from this mode |
| 3 | Comfortable controls and adjustable light assistance | Easier use without tiny text or unwanted bright effects | Medium | None |
| 4 | Explicit application pause rules | Avoid disruptive effects in chosen workflows | Medium | Current application identity only, opt-in |
| 5 | Energy-aware operation | Reduce unnecessary work during battery or thermal pressure | Medium | System power/thermal state |
| 6 | Camera recovery guidance | Explain unavailable capture without restarting repeatedly | Small–medium initially | Existing camera session status |
| 7 | Version awareness and signed update delivery | Make upgrades discoverable and trustworthy | Small for a release link; larger for an updater | Network access when checking/downloading |
| 8 | Per-display head zones | Better behavior at a multi-monitor desk | Large, exploratory | Numeric calibration and display arrangement |

“Medium” means changes spanning more than one service or UI state, with lifecycle testing. “Large” means changing a fundamental assumption of the current renderer or calibration model. Value is a reasoned hypothesis to test with actual users.

## Competitive context

HazeOver’s official help describes focused-window dimming, display-specific behavior, customizable shortcuts, and automation. These demonstrate established utility patterns for controlling a visual desktop effect. Its window-based behavior is different from AirVeil’s head-direction behavior; its claimed efficiency is not an AirVeil benchmark.[^3]

AirBuddy’s documentation emphasizes concise AirPods controls, an Action HUD, and preferences for when that HUD appears. This supports a design direction in which event feedback is configurable and brief. It does not establish that an unrelated app can safely reproduce AirBuddy’s device-management implementation or access every device signal through a public API.[^4]

Gaze Guard’s developer-supplied Mac App Store listing advertises camera-driven visual privacy, app selection, adjustable delays, Shortcuts, and a low-power option. These are useful comparison points, not independently verified accuracy or energy measurements. Its listing also says there are insufficient ratings for an overview; it cannot substantiate a claim that a large market already wants a specific AirVeil feature.[^5]

The recommended differentiation is therefore modest and concrete: minimize retained data, explain uncertain state, preserve a predictable exit, and offer a useful no-desktop-capture mode. Competing on unsupported claims of identifying shoulder surfers or knowing precisely which Apple device owns the AirPods would increase risk without resolving the current reliability problem.

## 1. Tracking health

**Proposed experience.** A small status row in Settings and an optional notch detail view would show one primary reason and one useful action: “Motion interrupted — reconnect AirPods,” “Direction needs a check — Refresh direction,” or “Ear status unavailable — removal automation is waiting,” when the policy is genuinely waiting. If a previously confirmed removal remains latched, show that active policy state instead; unavailable metadata does not undo it. A secondary disclosure would expose the separate states of motion, direction, camera, desktop capture, and removal automation. This extends the existing status strings into a coherent explanation rather than adding another continuously animated indicator.

A short, in-memory event list could contain entries such as “Tracking paused,” “Camera check finished,” and “Blur resumed.” A **Copy summary** action would present a preview before copying a deliberately small support record: app/macOS version, anonymous state categories, and coarse durations. It would exclude face images, desktop frames, window titles, device names, Bluetooth identifiers, file paths, and continuous angle history. Retention should be bounded, clearable, and off disk by default.

**Feasibility.** The current model already contains freshness, reference, capture, permission, and removal states. Apple documents headphone motion availability, updates, and connection status; those are useful observations, not proof of why an interruption happened.[^6] Apple also documents that supported AirPods can automatically move between Apple devices for audio. That contextual fact supports a troubleshooting explanation, but does not let AirVeil assert that an individual interruption was caused by an iPhone.[^7]

**Design decision.** Use “Tracking interrupted” or “Motion unavailable” when only motion loss is known. Reserve “Connection interrupted” for an actual connection-status event. Never replace unknown state with “AirPods removed,” “Using iPhone,” or “Protected.” The main surface should stay calm; diagnostic detail belongs behind a disclosure.

**Acceptance criteria.** Inject every pause reason and verify the primary explanation. An interruption must not start a camera or a removal action just to diagnose itself. Unknown ear state remains unknown. Copying the summary must expose only the advertised fields. Test that repeated events coalesce instead of filling a timeline or repeatedly opening the notch.

## 2. Solid veil without desktop capture

**Proposed experience.** The appearance picker would offer **Live blur** and **Solid veil** with a brief explanation. Live blur samples desktop pixels to create the effect. Solid veil draws a flat-color cover whose boundary follows the head, without reading the desktop. A first-time user who declines Screen Recording could choose the latter and still try a useful head-directed effect. Motion access remains necessary; camera assistance stays a separate opt-in.

**Feasibility.** This is an architectural proposal grounded in the existing AppKit windows, geometric input masks, and Metal renderer. A flat cover does not inherently need the desktop image. However, the current app starts capture before declaring the effect ready, so achieving this requires a separate readiness path, lifecycle ownership, and removal of accidental capture calls—not merely changing an opacity setting.[^1]

For the initial version, keep the covered interior fully opaque and move its boundary. A translucent region necessarily leaves underlying content visible. An optional feathered boundary must be described as a visual transition, not a confidentiality guarantee. Preserve the current rule that invalid tracking clears the effect and input blockers; stronger behavior on tracking loss would require a separately specified product decision.

**Tradeoffs.** This reduces the need to expose desktop pixels to AirVeil, but is less visually subtle than live blur. Other software may capture the underlying application through a different path. The mode should claim “does not capture your desktop,” not “cannot be screen-recorded.” Switching into live blur must explicitly invoke the normal permission flow; switching back must release capture resources.

**Acceptance criteria.** With Screen Recording denied, exercise startup, display changes, pause, sleep, quit, and reinsertion while asserting zero screen-capture requests and zero captured textures. Verify geometry at multiple display scales, a reachable pause shortcut, and consistent blocker behavior. A renderer failure must release blockers. Validate the claim with instrumentation before putting it in onboarding.

## 3. Comfortable controls and light assistance preferences

**Proposed experience.** Add a **Comfort** section with a text-first coach, a larger floating control window as an alternative to the notch, and **Face light: Automatic / Ask first / Off**. A limited intensity control can follow once real illumination tests establish a useful range. “Ask first” would show a single light offer for the current check; declining would suppress another offer until a later explicitly started check.

The current app already has Reduce Motion handling and accessibility labels. The new work is broader: readable scaling, an alternative to the fixed-width non-key notch panel, reliable keyboard navigation, and persistent control over automatic brightness-like visual effects. The four-step notch tutorial must still record completion only through **End tutorial**; an accessible Settings-hosted equivalent should share that completion state rather than silently bypass it.[^1]

Apple recommends purposeful motion and alternative ways to convey important information. Its accessibility evaluation guidance emphasizes completing common tasks with assistive technologies and supporting non-color cues.[^8][^9] Applied here, success needs a text equivalent to the green smile, and low-light assistance needs a discoverable Off action even if a tutorial occupies the notch.

**Tradeoffs.** Less animation can reduce the app’s visual novelty, but improve comfort and predictability. A dimmer face light may not produce a usable pose; the coordinator must report that honestly and keep the original check deadline. A warm/cool control should not be marketed as improving camera accuracy without testing.

**Acceptance criteria.** Complete onboarding, next/back/end, pause, light-off, and recovery with keyboard and VoiceOver. Verify all text at larger sizes and in both appearances. Evaluate contrast on actual materials, not color tokens alone. Off must prohibit AirVeil illumination across checks; Ask first must not auto-enable it. No preference changes the physical screen backlight. Test all lighting policies through cancellation, sleep, missing faces, and timeout.

## 4. Explicit application pause rules

**Proposed experience.** An optional rule could read **Pause the visual effect while Keynote is frontmost**. People would select apps themselves, see a short explanation of the consequence, and retain a visible “Paused by app rule” state. The rule should say whether removal automation remains active; “Pause everything” is too ambiguous for an app that also manages displays.

Apple’s workspace activation notification identifies the affected application through an `NSRunningApplication`. That is a plausible public foundation for application-level rules using bundle identifiers.[^10] The first version should neither inspect document titles nor infer that a video call, screen share, password entry, or private browser tab is active. A frontmost app is not evidence of those activities.

**Behavior contract.** Rules may add a pause reason. They must not erase a manual pause or override permission/session failures. When the selected app loses focus, AirVeil can resume only if the user had enabled the effect, tracking remains valid, and every other pause reason has cleared. Rapid switching should coalesce state changes, not queue camera checks.

**Tradeoffs.** This feature intentionally reveals the desktop during selected workflows. Describe it as a convenience rule, not an added privacy barrier. Avoid a default exception list: the same app can be public presentation software for one person and sensitive work for another. Store only chosen identifiers locally; do not create an application-usage history.

**Acceptance criteria.** Test manual pause during a rule, switching to Settings, rapid activation changes, app quit, session sleep, and stale tracking on return. Verify that rules never alter removal settings or replace a saved center. App-level observation should not introduce requests for Accessibility access unless a later, explicitly scoped feature actually requires it.

## 5. Energy-aware operation

**Proposed experience.** Offer **Energy use: Automatic / Smoothest / Reduced** with Automatic as a conservative adaptive policy. Under Low Power Mode or thermal pressure, AirVeil could reduce decorative animation, preview refresh, and desktop sampling where measured results support it. The main status should explain any visible reduction in smoothness, without claiming a precise battery saving.

Apple exposes Low Power Mode through `ProcessInfo.isLowPowerModeEnabled` and thermal state through `ProcessInfo.thermalState`; the inspected macOS 26.5 SDK marks the former available since macOS 12 and the latter since macOS 10.10.3.[^11][^12] The existing capture configuration requests a minimum frame interval of 1/60 second, while the renderer already coalesces work. Adaptive capture is a possible extension, not evidence that existing rendering is wasteful.[^1]

**Safety boundary.** Reduce presentation work before weakening sensing. Do not accept older motion as fresh, relax calibration thresholds, or stop presence processing while leaving the UI implying it is active. Any mode that changes availability of a safety-relevant feature needs an explicit status and behavior contract. The strongest first experiment is reduced preview/capture cadence with the existing evidence rules intact.

**Acceptance criteria.** Compare CPU, GPU, frame latency, and energy impact on the same Mac, displays, content, and scripted motions. Use several repeated runs on battery and mains power. Report measurements and variability rather than a marketing percentage. Stress Low Power Mode changes mid-check, thermal transitions, display attachment, and sleep. Verify that input blockers track rendered coverage and do not lag behind a lowered render rate.

## 6. Camera recovery guidance

**Proposed experience.** A failed camera check would say “Camera unavailable — Try again when ready,” with a clear indication that capture and Face light have stopped. Details could distinguish permission denial, interruption, device/configuration change, and an unreadable pose when those causes are actually known. This would extend the existing retry UI with more precise lifecycle feedback.

AVFoundation documents notifications for capture interruptions, interruption end, runtime errors, and start/stop state.[^13] Those are evidence about a capture session. They do not reliably identify which other app is using a camera, and the presence of a conferencing app does not prove exclusivity.

**Recommendation.** Begin with better explanations and an explicit retry. If later offering “Retry once when available,” bind it to one user-requested operation and preserve a deadline. A notification should never rearm unlimited automatic recovery or reopen the camera after cancellation. This is especially important after the recent idle-audio fix.

**Acceptance criteria.** Simulate interruption/end/error ordering, repeated notifications, permission revocation, and app/session shutdown. Confirm one bounded operation, immediate light cleanup, no stale frame acceptance, and no new center from an unsuccessful check. Run physical camera-contention tests across built-in-camera workflows before promising interoperability.

## 7. Version awareness and controlled updates

**Proposed experience.** Begin with a local About row showing version/build and **View releases**. A later opt-in **Check for updates** action could show the available version and release notes, followed by a normal install decision. Stable and beta channels should be explicit. Automatic background checks should be a separate preference, not silently introduced into an otherwise local app.

Apple’s notarization documentation distinguishes a Developer ID distribution identity from local development signing, and describes notarization as an automated check rather than App Review.[^14] The current DMG remains development-signed and non-notarized; publishing it on GitHub does not change that status.[^15]

Sparkle is a plausible macOS update framework. Its documentation recommends HTTPS delivery, signed update archives, protected signing keys, and appropriate application signing. An updater is a supply-chain feature with maintenance obligations, not simply a download button.[^16] The private GitHub repository also creates an access problem: authenticated browser downloads do not automatically become a public updater feed. Never embed a GitHub token in the app or change repository visibility to avoid designing distribution properly.

**Acceptance criteria.** For an initial release link, verify the destination and version text. Before shipping an updater, test signature failures, incompatible versions, offline behavior, cancellation, beta-channel changes, and permission continuity. The replacement app must quit safely and restore any brightness it owns. Developer ID/notarization and feed hosting need an explicit distribution plan; do not promise this path is free of account or hosting requirements.

## 8. Per-display head zones

**Proposed experience.** For a desk with two monitors, a setup flow could ask the wearer to deliberately face each display and label the resulting head zone. AirVeil could then adjust which display is obscured as the wearer turns. This goes beyond both existing display selection and the earlier named-profile proposal.

**Feasibility limit.** The current app uses one camera-forward reference. Desktop pixel positions do not determine real-world monitor angles, distance, or pose. An external screen also may not have a suitable camera anchor. The feature would need explicit per-display setup, independent invalidation after movement, and careful behavior between zones.[^1] It is a research prototype candidate, not a near-term guarantee based on enumeration APIs.

**Acceptance criteria.** Begin with simulated zones and visible numeric state, then test physical displays at varied heights and angles. Cover crossing a zone boundary, glancing between screens, closing the laptop, changed arrangement, removal, and reference loss. Require a usable manual pause throughout. Advance only if users find the setup worthwhile and errors do not repeatedly obscure the display they are trying to read.

## Existing backlog worth retaining

The following remain worthwhile but were already proposed. They should compete with the new ideas on effort and benefit rather than being postponed solely because they are less novel.[^2]

| Existing idea | Recommended refinement | Priority relative to new work |
|---|---|---|
| Check my setup | A non-actuating rehearsal with explicit sensing consent and no brightness/sleep commands | Pair with Tracking health |
| Timed pause | A visible deadline; ordinary Pause cancels automatic return | Strong small follow-up |
| Named desk/travel profiles | Save effect settings, never assume a saved center is still valid | Useful after state clarity |
| Open at login | Default-off, reflect actual macOS approval status | Small independent convenience |
| Shortcuts actions | Route through the same state rules as buttons | Follow a stable pause/recovery contract |

## Apple-style interaction direction

Keep the primary Settings view centered on what AirVeil is doing and what the person can do next. Put troubleshooting, rules, and performance detail behind progressive disclosure. Use system typography, familiar spacing, and restrained color. Reserve one prominent action for the next step; a status surface should not become a dashboard of equally weighted controls.

The notch should communicate short-lived status or a deliberate teaching flow. Put longer explanations and larger text into a normal, keyboard-focusable Settings surface. Offer menu commands for actions otherwise reached by hovering. A 44-point hit area is a useful project target for primary controls, not a claim that every macOS control must use that size. Check actual contrast, keyboard operation, VoiceOver descriptions, and reduced-motion behavior in both appearances.[^8][^9]

Proposed status language should separate **effect**, **tracking**, and **display automation**:

| Situation | Suggested primary text | Primary action |
|---|---|---|
| Valid heading, effect enabled | Following your head | Pause |
| Motion unavailable | Tracking interrupted; screen is clear | Connection help |
| Motion returned, direction unverified | Direction needs a check | Refresh direction |
| Ear metadata unavailable, no confirmed removal latched | Removal automation is waiting for ear status | Details |
| Selected app paused the effect | Visual effect paused for this app | Edit rule |
| Low-light assistance disabled | More light needed; Face light is off | Light options |

These labels are proposed copy, not an implemented redesign. They should not imply that visual privacy remains active while the current fail-clear policy has revealed the screen.

## Selection and validation plan

The first development candidate should combine Tracking health with the existing non-actuating setup rehearsal. That directly addresses uncertainty around paused media, handoff, wearer removal, and camera recovery. Build the no-desktop-capture veil next if permission minimization is a core positioning goal. Comfortable controls can progress alongside either, because fixed-size feedback and bright illumination affect basic usability.

Before picking a larger roadmap, validate the choices with a small, varied usability pilot. Include single-display users, external-monitor users, people who switch AirPods between devices, and people using keyboard or assistive technology. Ask participants to explain the current status and recover without help. Observe misunderstandings, unnecessary camera starts, failed tasks, and how often they need to pause; do not infer broad popularity from a few favorable comments.

Use scripted media-pause, phone-handoff, left/right/both-ear removal, sleep/wake, and camera-unavailable scenarios. Synthetic tests can establish policy and cleanup invariants; real hardware sessions are still needed to establish device behavior, camera performance, and comfortable lighting. No proposed feature should claim to solve an untested hardware case merely because its state machine passes tests.

Defer continuous shoulder-surfer surveillance, identity-based unlocking, silent AirPods routing changes, automatic re-centering from stillness, and a general-purpose AI assistant. They expand sensing, permission, or correctness requirements far beyond the narrow value proposition. A future manual “cover now” command may be useful, but any automatic cover-on-tracking-loss policy needs a separate usability and recovery design; it should not quietly replace today’s fail-clear behavior.

## Release continuity

The tutorial upgrade is already released as [AirVeil 0.13.0 beta 1](https://github.com/ShivHax-YT/AirVeil/releases/tag/v0.13.0-beta.1), from commit `851c4bc09cba62987d7dc9644e1074c3bd2409e6`. GitHub publishes the DMG, checksum file, and source archives. Its DMG SHA-256 matches the local artifact:

```text
135ed82b10c5bf3743093361b08c314e9d2d056b3cbacaf805654edd111778e6
```

This report is a documentation-only addition. It does not change the app, version, signing status, or DMG. Keeping the release tag tied to the shipped source preserves reproducibility; the new research can live in a later documentation commit on main.[^15]

## Sources

Primary product descriptions are cited as vendor claims. Undated web pages were accessed September 14, 2026; access dates are not publication dates. Apple API availability was checked against the installed macOS 26.5 SDK where stated. The cited source baseline is immutable so later app changes do not silently alter the evidence behind this report.

[^1]: AirVeil, source at [0.13.0 release commit](https://github.com/ShivHax-YT/AirVeil/tree/851c4bc09cba62987d7dc9644e1074c3bd2409e6), September 14, 2026. Inspected `README.md`, `Sources/AppModel.swift`, `DesktopOverlayController.swift`, `MotionService.swift`, `AirPodsWearState.swift`, `NotchCoachView.swift`, and `NotchOverlayController.swift`. Private repository access required. Supports the existing-feature inventory and architectural inferences.
[^2]: AirVeil, [Useful next features for AirVeil](https://github.com/ShivHax-YT/AirVeil/blob/851c4bc09cba62987d7dc9644e1074c3bd2409e6/research/NEXT-FEATURES.md), September 13, 2026. Private repository; prior proposals, not validation of implemented behavior.
[^3]: Maxim Ananov / HazeOver, [Help and Productivity Tips](https://hazeover.com/help.html), undated. Vendor description of dimming, multiple displays, controls, and automation.
[^4]: AirBuddy, [How to use and customize the Action HUD](https://support.airbuddy.app/articles/how-to-use-the-action-hud/), undated. Vendor documentation for compact feedback and visibility preferences.
[^5]: Veysel Kurnaz, [Gaze Guard: Screen Privacy, Mac App Store listing](https://apps.apple.com/us/app/gaze-guard-screen-privacy/id6758575687?mt=12), version 1.0.9 shown with August 4 update; listing accessed September 14, 2026. Features and privacy statements are developer-provided, not an independent audit.
[^6]: Apple, [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager?changes=latest_major), undated. Public motion and connection interfaces; local SDK header `CoreMotion.framework/Headers/CMHeadphoneMotionManager.h` also inspected.
[^7]: Apple Support, [Switch AirPods between Apple devices](https://support.apple.com/en-gb/guide/airpods/dev228ba3df8/26/web/26), guide for macOS Tahoe/iOS 26 and related systems. Describes automatic switching and the user-controlled connection preference.
[^8]: Apple, [Human Interface Guidelines: Motion](https://developer.apple.com/design/human-interface-guidelines/motion?changes=l_9_3), undated. Purposeful, optional motion and meaningful feedback.
[^9]: Apple, [Evaluate your app for Accessibility Nutrition Labels](https://developer.apple.com/videos/play/wwdc2025/224/), WWDC25, 2025. Common-task testing, contrast, color alternatives, larger text, and assistive technologies. Nutrition Labels are App Store metadata; these evaluation principles do not imply AirVeil has an App Store listing or certified accessibility support.
[^10]: Apple, [NSWorkspace.didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification?changes=___8_9_1_4_8%2C___8_9_1_4_8&language=objc%2Cobjc), undated. App activation notification and application identity payload.
[^11]: Apple, [ProcessInfo.isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled?changes=_9), undated. Read-only power-mode state and change notifications. macOS availability checked in installed `Foundation.framework/Headers/NSProcessInfo.h`.
[^12]: Apple, [ProcessInfo.thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property?changes=_2%2C_2), undated. Thermal status and resource-reduction guidance; availability checked in the same SDK header.
[^13]: Apple, [AVCaptureSession.interruptionEndedNotification](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionendednotification?changes=__2%2C__2), undated. Capture lifecycle notification and related session-state APIs.
[^14]: Apple, [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution?changes=_1_8_5), undated. Developer ID requirements, notarization behavior, and distribution workflow.
[^15]: AirVeil, [0.13.0 beta 1 release](https://github.com/ShivHax-YT/AirVeil/releases/tag/v0.13.0-beta.1), September 14, 2026. Authenticated GitHub page checked against local release commit and DMG hash; private repository access required.
[^16]: Sparkle Project, [Documentation](https://sparkle-project.org/documentation/), undated, current page accessed September 14, 2026. Update integration, archive signing, key custody, and hosting requirements. A production integration must separately review its selected version and current security advisories.
