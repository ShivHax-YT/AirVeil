# Useful next features for AirVeil

Research date: September 13, 2026. These are proposals for a later update; no extra features were implemented. Priority and effort are engineering judgments based on the current source, not promises or measured estimates. Small means a bounded settings/lifecycle addition; medium means changes across the UI, state machine, and validation.

The current app already has a synthetic head-turn preview, notch animation demo, display selection, a global pause shortcut, adjustable blur settings, camera-assisted center recovery, foreground presence, brightness restoration, and developer-only JSON diagnostics. The suggestions below extend those capabilities rather than relabel them.

| Priority | Proposed feature | Why it would help | Effort | Privacy impact |
|---|---|---|---|---|
| 1 | Guided **Check my setup** with non-actuating removal rehearsal | Makes left/right/both-bud behavior and presence decisions visible without repeatedly darkening or locking the screen | Medium | Local, explicitly started camera/motion check; no recordings |
| 2 | Named **Desk / Laptop / Travel** display profiles | Saves different left/right blur onset and effect/display settings for recurring workspaces | Medium | Local preferences only; no location tracking |
| 3 | **Pause blur for 15 minutes** | Temporarily clears blur for a demonstration or shared task and makes the return time visible | Small–medium | No new sensor or app monitoring |
| 4 | Opt-in **Open at login** | Makes the menu-bar app available consistently after restarting the Mac | Small | No new data; user-controlled login registration |
| 5 | **Shortcuts and Spotlight actions** | Enables keyboard-driven Pause, Resume, Show controls, and profile selection without finding the notch | Medium | Local app actions; no sensor or screen data returned |

## 1. Guided Check my setup

Offer a dedicated diagnostic session that says “Would black out: wearer remains seated,” “Would turn the display off: seat empty,” or “Cannot decide: face/body evidence unavailable.” Show which ear-state observation changed and which part of the current pipeline is waiting. Keep a visible **Done** button and time limit. The existing visual demo does not exercise these live inputs; this feature would.

The production coordinator already accepts injected presence, dimming, and sleep boundaries (`RemovalPresenceCoordinator.swift`), and `AppDelegate.writeDiagnostics` already exposes useful state. A rehearsal can use actual consented sensing while replacing physical actions with visible outcomes. It must clearly report that brightness restoration and password-on-wake were **not physically tested**. A short optional Copy diagnostic summary should omit images, device identifiers, window titles, account paths, and continuous angle history.

For development, measure acquisition-to-UI delay, camera-start duration, and alignment completion using Apple's `OSSignposter`; this adds timing evidence rather than inferring causes from a frozen UI. Apple supports named intervals/events and an Instruments timeline. [Apple OSSignposter documentation](https://developer.apple.com/documentation/os/ossignposter)

Ship gate: rehearsing left/right/both removal must execute zero real brightness writes, idle assertions, or display-sleep requests; exiting must stop its camera and preserve the user's original settings.

## 2. Named display profiles

Save a small set of profiles containing selected displays, left/right onset, full-blur angle, blur style, and obscuration strength. Start with explicit selection; matching a connected-display arrangement can suggest a profile later. This adds grouped presets to the existing individual controls and saved display selection.

Apple provides a display-configuration change notification; `UserDefaults` supports app-local persistent settings. These are sufficient building blocks for the settings and suggestion layer. A layout notification does **not** reveal a monitor's physical angle or prove that a saved camera center remains valid. Continue requiring a new centered check when the current camera/layout rules require one. [Apple display-configuration notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification), [Apple UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)

Ship gate: applying a profile cannot select a missing display, silently reuse an incompatible center, or treat a stale numerical heading as verified.

## 3. Pause blur for a chosen duration

Add a distinct **Pause blur for 15 minutes** item beside the existing immediate Pause action, with a countdown and **Resume now**. Keep the AirPods removal policy separately visible and unchanged; the label must not imply that all protection is disabled. Explicit ordinary Pause should cancel timed resumption.

A cancellable `ContinuousClock` deadline provides a nonblocking timer and continues accounting for elapsed time while the Mac sleeps. After a deadline, the app should only resume when the current session is active and tracking is valid; a timer must never wake/unlock the Mac or set a new center. [Apple ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock), [Apple cancellable clock sleep](https://developer.apple.com/documentation/swift/continuousclock/sleep(until:tolerance:))

Ship gate: sleep, quit, explicit Pause, permission loss, and invalid tracking prevent an unwanted restart; there is no polling camera session just to maintain the countdown.

## 4. Open at login

Add a default-off switch backed by `SMAppService.mainApp`. Show the actual registration/approval status and respect a change made in macOS Login Items. Keep normal startup in the menu bar, preserving the existing quiet startup behavior and permission gates.

Apple's Service Management framework supports registering the main app as a login item on macOS 13 and later. Registering the main application makes it launch at subsequent logins, subject to user approval; registration status distinguishes enabled from approval-required. No privileged daemon or hand-written LaunchAgent is needed. [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [Apple registration behavior](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), [Apple registration status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum)

Ship gate: switching it off removes registration, disabling it in macOS is reflected in AirVeil, and an installed signed build launches without an unsolicited settings window or permission request.

## 5. Shortcuts and Spotlight actions

Expose a few explicit actions: Pause blur, Resume blur, Show notch controls, and Select profile. This adds system-level discoverability and composition to the existing fixed global pause shortcut. Route every action through the same AppModel methods as the UI; Resume must retain permission, presence/brightness restoration, and tracking checks.

Apple documents App Intents support for Shortcuts and Spotlight on Mac, including running app actions from Mac automations. The app does not need a language model for these actions. This repository currently builds with a direct `swiftc` script, so validating App Intents metadata extraction and discovery in the signed app is part of the work, not an assumed result of adding protocol conformances. [Apple WWDC25: Develop for Shortcuts and Spotlight with App Intents](https://developer.apple.com/videos/play/wwdc2025/260/)

Ship gate: actions appear in the actual installed app's Shortcuts/Spotlight integration, never change center without an explicit setup action, and expose only settings/action results rather than camera, desktop, or motion content.

## Recommended order

Start with **Check my setup** because it directly reduces the effort of diagnosing the removal, presence, and pause behavior just reported. Add **profiles** next for daily convenience. **Open at login** is the smallest independent addition. Timed pause and Shortcuts can follow once their resume/cancellation behavior has been validated against the current state machine.
