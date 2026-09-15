# AirVeil goal checklist — build 31

15 September 2026. Build 31 is installed and verified. This review reconciles the original seven reported issues, the five-feature goal, and subsequent wearer feedback.

## Latest requested change

Enable blur is the broad primary notch action. Set center is the secondary action on the right. The primary action still changes to Pause or Turn off feature when appropriate; camera setup and availability gates keep their existing meaning. Both actions have 44-point hit targets. The paused status no longer keeps claiming brightness is being restored after cleanup has completed.

## Completed implementation and acceptance

| Area | Evidence and scope |
|---|---|
| Both-AirPods removal and return | Wearer confirmed seated dimming stays dim, and brightness returns on reinsertion or Turn off feature. Build 30 trace records roughly 40 seconds occupied/dim with zero sleep requests. |
| Direct notch Enable | Wearer explicitly confirmed initial notch → wear reminder → return → face-direction check → automatic blur. The saved build 30 trace captured waiting only; acceptance of the later steps is wearer testimony, not an invented recorded alignment trace. |
| Off persistence | Normal quit/new PID/launch snapshots show Off remains paused, cameras off and brightness restored. Explicit notch Enable then cleared pause and showed the reminder. |
| Dim and Lock controls | Independent switches implemented; Lock defaults on, Dim off until opted in. User currently enabled both. |
| Dismiss × | Presentation-only. Wearer confirmed dismissing while AirPods remain out still allows dimming; monitoring and later return remain enabled. |
| Head sync | Wearer confirmed illustrated head, arc marker, and degree readout follow physical turns. |
| Dock and Command-Tab | Wearer confirmed both. Settings has ordinary window priority; notch guidance has a higher nonactivating level. |
| Settings and tutorial | Five tabs; all 16 installed tour steps inspected. Spotlight includes dependent controls. Pointer track clicks, Center and direction selection verified. |
| Visual and copy revisions | Glass permission cards, blurred/aligned side cards, removed blue outline, stars/meteors and expanded notch animation implemented. Policy reader/crash and copy work recorded in previous milestones. No exhaustive zero-error claim. |

## Remaining verification and limitations

- Automatic departure in current lighting, followed by original-brightness recovery in both return/unlock orders. Repeated automatic cycles remain unverified; four historical build 27 manual-lock/Sleep cases passed.
- Physical low-light or neutral seat-loss explanation → brightness restored → fresh seat check. Build 30's seated trial stayed visible, so this sequence was not needed. Its safety changes passed automated checks but physical departure acceptance remains open.
- Independent left/right ear removal remains a platform limitation when motion continues from the other AirPod. The implementation uses sustained motion loss, not private per-ear wear metadata.
- Manual tutorial slider dragging and live minimum-size interaction remain unverified; native minimum-size renders and installed track clicks passed.
- Native window tests establish ordinary levels, not precedence over protected macOS UI or every Space/fullscreen case.

See [build 30 evidence](GOAL-CHECKLIST-0.15.0-30.md), [build 29 failure and session record](GOAL-CHECKLIST-0.15.0-29.md), and [historical physical brightness tests](SETTINGS-WEAR-AND-WAKE-0.15.0-24.md).

## Build 31 verification

- Focused notch suite passed: 135 native lifecycle checks and 44 rendered states (`build/notch-primary-enable-controls.log`). All five control variants fit; root inspected the paused primary-action layout at original resolution.
- Release compilation and packaging passed (`build/build31-package.log`). Full behavioral regression remains the passing build 30 suite; build 31 changes only control layout/hit targets and a status string.
- Normal quit and LaunchServices restart installed build 31. Strict signature, installed executable/DMG identity, bundled policies, and exclusion of developer preview commands all verified (`build/validation/release-0.15.0-build31.json`).
- Initial diagnostics confirm unlocked/active, cameras off, display not dimmed, no pending brightness restore (`build/validation/build31-after-install.json`). Show Notch Controls was invoked in the installed build; computer-control captures expose Settings rather than the separate nonactivating notch panel, so native renders are the layout proof.
- DMG SHA-256: `cdf99d5864ed1640fe577644d5a4cc39b8a8e7fe1e83015233a4190df0c026b5`; executable SHA-256: `80fb5c65f06679fb0608aca7379800b9012b1dca730ade74de3aa2fe21d6ddfd`. Build 30 installer is retained locally. No push or public release.
