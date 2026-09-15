# AirVeil goal checklist — build 30

15 September 2026. Build 30 is installed after the wearer confirmed two false locks while seated in build 29. Full regression and package verification pass; the new physical retest is in progress.

## Scope

- Require analyzable foreground-region evidence before missing detections can establish departure. Keep an already-away seat check possible when valid evidence supports it.
- After dimming, restore brightness and discard pre-restoration absence evidence before deciding that the wearer has left. Explain measured darkness as darkness; use neutral seat-recheck wording when darkness is unproven.
- Preserve dim/lock controls, rewear brightness restoration, explicit Off, dismissal-only ×, and lock/sleep recovery barriers.
- Record numeric image-quality diagnostics without images or identification data.

## Physical evidence and pending work

The [build 29 record](GOAL-CHECKLIST-0.15.0-29.md) retains the failing trace and wearer confirmation. × is functioning as requested: the wearer clarified the AirPods were still out when the display stayed dim. Dismissal does not disable monitoring. A later return restored brightness.

Pending after this fix: low-light sequence and seated false-lock retest; automatic departure with repeated brightness recovery in both return orders; direct notch Enable route; attributed Off/relaunch/re-enable chain; manual tour dragging and minimum-size live interaction. Earlier accepted head/arc/degree and Dock/Command-Tab behavior remain recorded.

## Focused verification

- 419 AppModel lifecycle checks passed in `build/build30-appmodel.log`. Updated integration expectations exercise the announcement interval and fresh absence after verified restoration; manual lock/sleep recovery cases retain their owned-brightness baseline coverage.
- 163 coordinator checks passed in `build/build30-removal-recheck.log`, including dim writes in flight, blocked old absence during announcement/restoration, cancellation, one-time restoration, and bounded generic uncertainty cleanup.
- 135 native notch lifecycle checks and 39 rendered states passed in `build/notch-seat-recheck-reason.log`. Root inspected the announcing image and the fresh original-resolution `seat-recheck-restored-final-review.png`; both controls and the neutral text are visible. An earlier tool rendering omitted controls although decoded file pixels contained them; the fresh original-size view resolved the discrepancy.

The regional measurements are visibility heuristics, not proof of physical wearer detection. The build 29 pre-dim failure's cause cannot be established retrospectively because its trace lacks regional quality and detector counts. New numeric diagnostics support the next test.

- Presence focused suites passed: 85 tracker checks and 47 capture/quality checks (`build/presence-seat-quality-tracker-2026-09-15.log`, `build/presence-seat-quality-service-2026-09-15.log`). Coverage includes real synthetic pixel buffers with a bright background/dark seat, flat or clipped regions, detailed usable regions, rejected nearby human geometry, initial already-away checks, queued pre-restore frames, and JSON-safe nonfinite diagnostics.

## Build 30 installation

Full regression passed (`build/build30-regression.log`), including 419 AppModel, 163 coordinator, 85 presence geometry, 47 capture/quality checks and actual 1×/2× Metal rendering. Normal quit and LaunchServices restart installed the strictly verified package; policies and executable match the DMG and developer preview commands are excluded (`build/validation/release-0.15.0-build30.json`). The prior build 29 DMG is archived under `build/releases/iterations/build-29/`.

Installed diagnostics show active/unlocked, steady motion, completed camera alignment, seat ready, both cameras off, no pending brightness restoration, Dim/Lock on, and the user-selected 1% target preserved (`build/validation/build30-after-install.json`). The new seated retest records `build/validation/build30-seated-recheck-cycle1.jsonl`; physical success is not yet claimed.

DMG SHA-256: `1e37b2b7444e3c72fd83663a807edc06fde142a69c34d6b5c359698e23773eb2`. Executable SHA-256: `f6053603ec11604bd9fcd62c82f02dbb3763c0c6111efd5bd001724671ad9054`. No push or public release.
