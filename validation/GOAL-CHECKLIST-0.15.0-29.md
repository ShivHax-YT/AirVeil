# AirVeil goal checklist — build 29

15 September 2026. Build 29 repairs a stale cached lock state discovered while reviewing the remaining goal. The full regression passes and build 29 is installed with verified package identity.

## New finding and correction

A synchronized before/OS/after probe found build 28 reporting `screenLocked=true` with all workspace awake/active flags true. The current macOS session was on-console and login-complete, with the lock key absent: the normal unlocked schema recognized by the existing reader. Evidence: `build/validation/build28-stale-lock-state-proof.json`. This was not an explicit false lock value.

Every lock notification still suspends work immediately. The app now reconciles a cached lock only after all workspace flags are active, two seconds without another lock observation, and at least five valid unlocked samples spanning one second. Missing or malformed evidence resets confirmation; long polling gaps do not count as continuity. Present flags must be Boolean values. The new `screen-state-reconciled` diagnostic event identifies this internal correction. It does not unlock or wake macOS.

Recovery uses the existing owned-brightness restoration barrier before resuming cameras or desktop effects. A new lock defeats late recovery completion; Turn off feature and shutdown remain authoritative.

## Remaining acceptance

The [build 28 checklist](GOAL-CHECKLIST-0.15.0-28.md) retains completed implementation, native UI checks, and installed tutorial evidence. The following still require physical acceptance:

- Low-light explanation → brightness restored → continued seat monitoring, followed by automatic departure in current lighting.
- Three automatic-departure brightness cycles per AirPods return order. The four build 27 confirmed cases cover both orders after manual lock and actual Sleep, not three repeats each.
- Reminder × hides only the animation; returning AirPods still aligns and starts normally.
- Direct notch Enable → waiting → physical return → camera alignment → automatic blur.
- An attributed Turn off → normal relaunch → remains paused → explicit Enable chain.
- Manual tutorial slider dragging and minimum-size live interaction. Installed track clicks, Center, and direction selector passed; native minimum-size renders passed.

Independent Lock/Dim switches, low-light guidance, and reminder dismissal are implemented. Lock defaults on and Dim off until manual opt-in. Individual-ear removal remains unverified: public motion can continue from the other ear and does not expose reliable per-ear wear status.

## Build 29 validation

- Focused lifecycle suite: 415 checks passed (`build/appmodel-stale-lock-2026-09-15.log`).
- Full regression: exit 0 (`build/build29-regression.log`), including brightness, removal, camera, motion, permissions, geometry, and actual 1×/2× Metal rendering.
- Package/install verification: strict signature passed; installed executable and bundled policies match the DMG; developer preview commands excluded (`build/validation/release-0.15.0-build29.json`). Build 28 installer retained under `build/releases/iterations/build-28/`.
- Fresh installed diagnostics report active/unlocked, no pending brightness restoration, both cameras off, and Dim off (`build/validation/build29-after-install.json`). Initial Settings rendered normally. A subsequent computer-control capture failed; no physical test is inferred from it.
- Restart naturally resets cached state. The installed startup snapshot therefore does not prove the delayed-notification reconciliation path; that path is covered by the focused regressions and awaits a naturally occurring runtime event.
- DMG SHA-256: `29845375898bf43b395cb6954912bc024c89b9ed784aa048f769c3cc9220b4b6`.
- Executable SHA-256: `d545981fdbe7eef377d8ebc1805ab0a381374776711d430a7c89d7f0f51a3194`.

No public release or push was made. Physical acceptance remains pending.

## Physical test after build 29

The wearer confirmed both AirPods in and Dim enabled. Fresh diagnostics showed steady motion, a finished camera check, and a valid seat reference. The selected dim target was 1%. `build/validation/build29-low-light-cycle1.jsonl` captures the test.

- Two automatic display-sleep requests occurred while the wearer reports remaining seated. The first preceded any seated confirmation or dimming; the second followed seated confirmation and a 100% → 1% dim. Both are false-lock failures, not accepted departure coverage.
- `presenceLowLight` stayed false, so the requested low-light recovery animation was not exercised. The current whole-frame mean threshold cannot establish that the foreground seat is analyzable.
- A later seated attempt dimmed and restored on AirPods return, confirmed by the wearer.
- The wearer dismissed × while AirPods remained out. Monitoring continued and the screen dimmed, as requested. The trace later shows fresh motion, restored brightness, and the journal cleared; the wearer clarified this was not a failure after reinsertion. × remains presentation-only.

Further physical testing is held while false-lock handling is corrected.
