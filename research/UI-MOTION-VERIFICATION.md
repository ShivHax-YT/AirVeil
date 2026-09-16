# Permission UI motion verification — 2026-09-16

The permission fixture uses a fake provider. Permission requests and System Settings opening deliberately fail if invoked. It never starts sensors or live desktop capture.

## Verified

- Release-optimized (`swiftc -O`) permission fixture: 20 native renders at 800×850 and 740×660, plus six real scroll-to-end consent checks.
- Thirty forward/back state changes spaced 25 ms apart, including resize during transition, repeated with normal and reduced motion.
- Latest navigation intent remains selected; exactly one reader remains after settling; unread cards stay unread during navigation and resize.
- Replay interrupts an entering card, returns to welcome without a retained reader, and permits a fresh read-to-end afterward.
- Reduced motion immediately replaces the reader: exactly one reader exists at each 25 ms checkpoint.
- Final motion-only rerun passed all 60 state changes and subsequent replay/review checks.
- Render review identified overlapping side-preview labels; the final source shows only the nearest preview label. Compact camera output was reinspected after the correction.

## Narrow timing comparison

Same optimized stress fixture, archived baseline `975a7e2` versus updated source, executed serially after compilation. Measurements cover synchronous model mutation plus forced AppKit layout. They do **not** measure displayed frames, GPU cost, hitches, input-to-photon latency, or energy use.

| Normal motion | Baseline | Updated |
|---|---:|---:|
| Median | 3.241 ms | 2.724 ms |
| p95 | 3.909 ms | 3.090 ms |
| Maximum | 8.567 ms | 8.030 ms |

Thirty samples per run; treat these as local diagnostic evidence, not a general performance guarantee. The baseline still retained multiple reader views at the one-second checkpoint after rapid navigation and therefore failed that new settling assertion. This establishes a slower settling condition, not permanent state corruption. Updated reduced-motion replacement measured median 8.258 ms / p95 9.744 ms; it performs the replacement immediately rather than deferring work across a transition.

Logs: `build/ui-polish-permission.log`, `build/ui-baseline-motion-final.log`, and `build/ui-polish-motion-final.log`. Render artifacts are under `build/permission-previews`.

## Remaining verification

The desktop was locked during final verification. Offscreen AppKit caching does not completely reproduce live Liquid Glass composition, and its synthetic accessibility tree did not expose the permission action. Consequently, interactive native AX actions and physical high-refresh presentation are unverified. Outgoing permission/welcome/summary controls were reviewed for phase guards, disabled state, hit testing, and accessibility hiding; that code review is separate from runtime action proof.

Run the optional interactive fixture on an unlocked desktop:

```sh
bash scripts/test-permission-ui.sh --motion-only --accessibility
```

This opens only generated fixture UI, requires an unlocked desktop, verifies the current AX skip action, then tries the retained outgoing action against the next card. It must not advance the next permission. The default script remains offscreen and reports this interactive gate as skipped.

Full Xcode/Instruments is not installed (`xctrace` is unavailable). Apple's [SwiftUI performance session](https://developer.apple.com/videos/play/wwdc2025/306/) recommends correlating SwiftUI update lanes with Time Profiler and Hangs/Hitches on a Release build. That remains the appropriate follow-up for a displayed frame-pacing claim.
