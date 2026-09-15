# Permissions, policies, and release validation — 0.15.0

Reviewed September 14, 2026. Source version **0.15.0, build 20**. This record separates automated evidence, live launch observations, and remaining acceptance.

## Implemented

- Permission cards precede the Settings tour: Camera, Screen Recording, and Head Tracking. The access action requires reviewing the details; every permission can be declined. Saved progress and explicit choices do not substitute for live macOS authorization. See [PermissionOnboarding.swift](../Sources/PermissionOnboarding.swift), [PermissionOnboardingProvider.swift](../Sources/PermissionOnboardingProvider.swift), and [PermissionOnboardingView.swift](../Sources/PermissionOnboardingView.swift).
- [AirVeilSetupView.swift](../Sources/AirVeilSetupView.swift) and [AppDelegate.swift](../Sources/AppDelegate.swift) gate normal startup and transition from permissions into the interactive tour. Camera/screen setup does not start a live effect; the explicit motion request may briefly run and stop a motion session.
- [LegalDocuments.swift](../Sources/LegalDocuments.swift) opens the three policies from bundled Markdown in native sheets before permissions and from Settings. [Resources/Legal](../Resources/Legal) is canonical. External reference/contact links open only when selected.
- The final visual source uses native `glassEffect` on macOS 26, a material fallback on macOS 14/15, and a solid surface with Reduce Transparency. Inactive side cards remain dimmed, blurred, noninteractive, and hidden from accessibility. [PermissionStarfieldBackground.swift](../Sources/PermissionStarfieldBackground.swift) adds 44 deterministic white stars, an 18 fps maximum requested animation cadence, and one short meteor every 18 seconds. Reduce Motion removes the timeline; an AppKit window-visibility observer also suspends it while hidden, occluded, minimized, or inactive. The native-glass choice follows the user's latest request and supersedes the earlier standard-material preference in the [onboarding research](../research/ONBOARDING-CONSENT-ACCESSIBILITY-2026-09-14.md).
- The both-AirPods workflow uses public motion loss rather than private Bluetooth ear metadata. Camera-assisted seated dimming restores owned brightness when motion returns. Unknown/unavailable presence does not request sleep; automatic display management with camera assistance or seated dimming off can request sleep directly. The [removal validation record](AIRPODS-REMOVAL-2026-09-14.md) contains the detailed implementation and physical evidence.

## Automated and artifact evidence

The stored [regression log](../build/permission-dimming-regression.log) records passing motion, camera, AppModel, brightness/restoration, presence, capture, input, and actual 1×/2× GPU checks. Examples include 15 wear-policy checks, 51 MotionService lifecycle checks, 278 AppModel/removal checks, and 106 brightness/ownership checks. Device providers are injected in lifecycle tests; these passes do not actuate real camera, brightness, or display sleep. The log is a saved run, not evidence that every later UI edit was included in it.

Permission policy checks were run separately: [test-permission-onboarding.sh](../scripts/test-permission-onboarding.sh) passed **29** fake-provider checks for review/decline choices, persistence, actual-grant gating, cancellation, and stale callbacks. The subsequent visual changes do not change that controller. The final frozen native-glass/starfield source, including the own-window observer and 2.1-second meteor, passed [test-permission-ui.sh](../scripts/test-permission-ui.sh): **20** native permission-card renders and **6** real scroll-to-end gates at regular/compact sizes, with unavailable/denied states, no warnings, and no OS prompts or sensors. Final outputs are under [build/permission-previews](../build/permission-previews). Results were observed in the agent turn; no dedicated final UI log was retained.

The native render helper's `cacheDisplay` omits the system glass background and some composited card offsets. Its PNGs can show black text over black despite the live glass layer. Representative outputs were inspected, but these captures cannot establish the actual material, text contrast, stack depth, twinkle, or transition quality. Passing the scroll gates remains valid and independent of that compositing limitation. The starfield component passed a Swift 6 typecheck targeting macOS 14; its lifecycle/observer cleanup was independently reviewed, without a runtime energy benchmark.

[test-legal-ui.sh](../scripts/test-legal-ui.sh) loaded all three bundled documents with their public contact and passed six native reader renders, covering light and dark appearance. Artifacts are in [build/legal-previews](../build/legal-previews). The successful rerun was observed in the agent turn; [build/legal-render.log](../build/legal-render.log) belongs to the earlier failed helper invocation and must not be cited as a passing run.

An earlier visual-source build is recorded in [build/glass-onboarding-build.log](../build/glass-onboarding-build.log). Strict signature checks passed for that built and installed app during live release work. A separate read-only inspection confirmed version/build and byte-for-byte equality of the three bundled policy files with source. The later native-glass/starfield revision needs its final build/package evidence recorded separately; the earlier DMG is not evidence for that revision. Shell syntax and `git diff --check` passed. Local build logs and PNGs are ignored artifacts and may not accompany a source checkout.

## Launch and visual boundaries

The isolated **LegalReader** helper aborted during AppKit application registration when run in the sandbox, before its policy view ran. Running that helper outside the sandbox completed the six renders. This failure was not treated as a production AirVeil policy-reader crash.

A direct launch of AirVeil's executable through the automation host caused macOS privacy access to be attributed to the responsible host process. Launching the installed `.app` normally through LaunchServices corrected the attribution. Acceptance uses that normal application launch path; this does not establish fresh-permission behavior on every Mac.

Live inspection of the installed app verified that the Privacy Policy footer opens a native sheet containing the actual bundled sections and public contact. **Done** had initial keyboard focus, and Escape closed the sheet cleanly back to the Camera card. Diagnostics still showed setup active, direction/presence cameras off, and no fresh motion. No permission was requested by opening the policy. Tab produced no observable accessibility-tree change, so full keyboard navigation and VoiceOver acceptance are not claimed.

Live screenshot capture through Computer Use failed with error **3812**. Neither accessibility-tree inspection nor the limited render captures substitutes for the user's visual acceptance of the latest glass/starfield update; that feedback remains pending. Physical seated dimming and restoration at the user's 2% target were separately confirmed; departure sleep/lock, a physical 0% run, and complete direction recovery retain the limits recorded in the removal validation document.

## Policy and distribution audit

The source audit found local image/motion processing, native saved preferences and camera configuration, session-only seat geometry, a brightness recovery journal, and explicitly enabled local JSON diagnostics. No app Internet client/server, advertising/analytics SDK, embedded browser, browser-cookie implementation, or automatic upload was found. Support email and separately visited websites are disclosed independently. This is a source audit, not a network measurement, secure-erasure guarantee, or legal-compliance certification. Primary sources and jurisdiction assumptions are in the [privacy research](../research/POLICY-PRIVACY-RESEARCH-2026-09-14.md) and [terms research](../research/TERMS-AND-RELEASE-DISCLOSURES-2026-09-14.md).

[build.sh](../scripts/build.sh) requires all three nonempty policies and copies them into the signed bundle. Default `AIRVEIL_RELEASE` builds write `build/AirVeil.app`; `--development` writes `build/development/AirVeil.app`. Both preview menu entries and their selector are guarded by `AIRVEIL_DEVELOPMENT`; the inspected release binary contained neither the preview menu label nor selector. [package-dmg.sh](../scripts/package-dmg.sh) rebuilds and packages only the default output, with an Applications shortcut and installation notes. It produces a DMG/checksum but does not publish a release. Final DMG verification/publication is recorded separately; development signing is not Apple notarization.

## Final installer and installed preview

The final Liquid Glass and starfield source was built and packaged successfully in `build/starfield-package-0.15.0.log`. The DMG was mounted read-only: strict signature verification passed, all three policies matched their canonical source, both developer preview strings were absent, and the packaged executable matched the built and installed executable byte for byte. The installed app was reopened through LaunchServices, and its Camera permission card and policy controls were verified through accessibility. Visual feedback remains pending because native screenshot capture still fails.

- Installer: `AirVeil-0.15.0-apple-silicon.dmg`
- SHA-256: `b5d7bb48b21a71d82cd90da361ffd74fa43bed2cf18cbc84a723b68e7677251f`
- App executable SHA-256: `06295b3d450743bffd8afe72209072719c55c256dde157da3177866d26b3661c`
- Machine-readable local evidence: `build/validation/release-0.15.0.json`.

The earlier installer is retained under `build/releases/iterations/before-starfield/`; it is not the final artifact. No GitHub release has been published by this packaging operation.
