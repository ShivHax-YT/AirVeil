# Zero brightness and individual AirPod removal

Reviewed against the macOS 26.5 SDK and the current AirVeil sources on September 14, 2026.

## Behavior implemented

- Confirmed occupied seat requests actual built-in-panel brightness `0`, holding the existing idle-display assertion. It does not invoke display sleep or lock.
- Targets now accept `0...0.5`; default is `0`. A zero request must read back within `0.000001`, rather than accepting a visibly nonzero value under the normal slider quantization tolerance.
- The original, unrounded brightness remains in the existing durable restore journal. Reinsertion restores that value after the presence camera has stopped. Manual brightness changes retain priority.
- Departure releases the idle assertion and stops capture without restoring brightness first, preventing a bright desktop flash before display sleep. The journal survives until verified active-session recovery. A failed sleep dispatch attempts active brightness recovery.
- No new automatic unlock, password-policy change, screen-saver configuration, or simulated user activity was added.

## Ear-state evidence

Apple's public headphone delegate reports connection events affected by Automatic Ear Detection. `sensorLocation` identifies only the bud supplying motion. Apple demonstrates a source handoff when that bud is removed, and notes that other factors also select the source. Consequently a source change alone is not a removal signal, and live motion from the remaining bud does not prove reinsertion. [Apple, WWDC23 Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179/)

For the nonstreaming bud, the implementation supplements public events with guarded, read-only IOBluetooth metadata. Hammerspoon's own source uses `primaryBud`, `primaryInEar`, and `secondaryInEar`; it maps zero to in-ear and primary-bud value 1 to left. These are private compatibility APIs, not a supported Apple per-ear contract. [Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/battery/libbattery.m)

`SystemAirPodsWearReader` reads already paired devices and requires exactly one connected Apple device reporting multi-battery and ear-detection support, with Automatic Ear Detection enabled. Every private getter must exist with the expected byte/boolean ABI. Unknown values, multiple eligible devices, or missing capabilities return no metadata. The app neither scans nor pairs nor changes Bluetooth settings. Selection uses an anonymous, process-local token; no names, addresses, device history, or metadata are saved.

Bluetooth framework reads run on one dedicated utility queue with at most one request in flight. The UI receives only the most recent timestamped result. Slow framework IPC cannot stall the main thread or headphone acquisition, and stale evidence expires to unknown.

`AirPodsWearEvidence` requires two consistent observations spanning at least 0.2 seconds. A wear baseline requires fresh motion. A decrease in the worn-bud mask latches removal; an increase clears it. Missing metadata and public transport reconnection cannot erase a known per-bud removal merely because the remaining bud continues streaming. A visible manual recovery action can clear unavailable metadata. Public-only episodes retain their previously working reconnect recovery.

The reader is enabled only for the individual-AirPod removal feature. The application must supply `NSBluetoothAlwaysUsageDescription`; Apple requires the purpose string for Bluetooth-interface use. The present non-sandboxed application needs no sandbox Bluetooth entitlement. [Apple purpose-string requirement](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription), [Apple Bluetooth sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth)

## Activity Monitor and acquisition continuity

Opening another app is not a removal signal. The production delivery buffer already validates each physical sample before coalescing visual updates. The fusion sample now explicitly carries this proof, and actual source/receipt gaps of at least 0.3 seconds advance the epoch. This lets the fusion engine distinguish a busy UI dropping intermediate visual deliveries from a real acquisition gap, without trusting a changed source, reset clock, or unobserved sensor interval.

## Verification and limits

Only fake hardware tests were run for changes in this subtask:

- 106 brightness/journal/zero/restoration/suspension/assertion checks.
- 46 removal-presence checks, including zero while present, departure without a brightness flash, sleep failure recovery, and cancellation races.
- 22 pure per-bud evidence checks.
- 55 real MotionService lifecycle checks with injected sensor/transport/clock, including removal of either nonstreaming bud while motion continues, reinsertion, metadata loss and transport reconnect preserving known removal, and continuous acquisition behind a delayed UI.
- 62 motion-delivery checks.

A local read-only Objective-C probe verified runtime availability of the Bluetooth class selector and paired-device enumeration. It found zero currently connected headsets, so the private getter values on the user's specific AirPods have not been physically verified. This subtask performed no brightness writes, camera capture, ear-removal test, display sleep, lock, or installation. The user requested their physical checks at the end.

Private per-bud compatibility can change with macOS/AirPods firmware. Unsupported metadata falls back to the previously working public connection-event behavior, with an honest diagnostic status; it never fabricates missing per-ear evidence.
