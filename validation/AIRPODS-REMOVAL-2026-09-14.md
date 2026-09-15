# AirPods removal and return repair — 14 September 2026

## Live read-only findings

- The user confirmed both AirPods were worn. The running app reported approximately 50 motion samples/second from the right AirPod, camera assistance on, removal behavior on, and a remembered seat. Individual-ear metadata remained unavailable.
- System Settings showed Automatic Ear Detection on and the AirPods connected. No setting was changed. Its model was AirPods Pro 3; no names, addresses, serial numbers, or images are included here.
- A bounded anonymous IOBluetooth probe, repeated after the both-in confirmation, reported one connected ear-capable Apple device. `isMultiBatteryDevice`, `inEarDetect`, `primaryBud`, `primaryInEar`, and `secondaryInEar` all returned zero immediately and after 10 seconds on the main run loop. These defaults cannot establish the actual wearing state; `inEarDetect = 0` conflicts with the visible enabled setting.
- The probe received two IOBluetooth connection notification callbacks. These establish that its run loop delivered framework callbacks. They are **not** observations of Core Motion removal/reinsertion callbacks or proof of a physical wearing transition.
- A separate read-only compatibility probe reported Bluetooth authorization granted, no devices from BluetoothManager, and CBController error `CBErrorDomain -71168`. Those routes did not provide usable placement evidence. No additional entitlement or Bluetooth setting was changed.
- A typed, read-only call to IOBluetoothDevice's private `connectedDevices` collection also returned no entries. Substituting that collection for the paired-device query therefore did not supply the missing ear values.
- The Mac's screen-lock delay was verified as immediate. The missing event was upstream of the display-sleep service.

## Root causes and changes

The strict per-ear implementation removed the former public connection fallback. Because the private fields above are unavailable on this setup, neither removal nor reinsertion could emit a per-ear event. Separately, a real nonstreaming-bud change could leave the same fresh motion source and alignment valid, suppressing the camera recheck.

1. Confirmed private-metadata removal and return now invalidate the old motion alignment even if the partner keeps streaming. Camera recovery waits for return and measures against the saved screen center.
2. A genuine public disconnect after prior fresh motion can start one debounced local seat check when the existing removal/presence options and a seat reference are available. A seated or uncertain result ends the check without dimming or sleeping. Only confirmed absence permits display sleep. Missing seat geometry cannot fall through to display sleep in this path.
3. A public reconnect with fresh motion permits one camera direction check. A sustained sample gap followed by return permits one check after a previously successful alignment; repeated failed/noisy epochs cannot create a retry loop.
4. Removal status explains when macOS does not provide individual-ear state instead of claiming the complete removal behavior is ready. Anonymous counters distinguish connection-based presence checks from confirmed per-ear removals.

The private getter eligibility checks remain strict. A default zero is not treated as proof that both buds are worn. Audio handoff, sample gaps, and source changes alone do not prove removal or authorize a seated blackout.

## Verification scope

Production coordinator and lifecycle tests inject only the camera, motion transport, brightness, display-sleep, and preference boundaries. Regressions cover same-source per-ear removal/return; public reconnect and sustained-gap recovery; saved-center preservation; no repeated checks for the same event; removal/presence opt-outs; no seat reference; no prior fresh motion; sample gaps without disconnect; present/unknown connection checks without brightness or sleep; confirmed absence; and stop-before-heading recovery.

This repair does **not** establish reliable independent left/right wear detection on this Mac while the legacy metadata is unavailable. A physical non-source-bud removal may produce no usable event. Physical left-only, right-only, both-out, reinsert, seated dim, departed-seat lock, and return-brightness behavior must be checked on the installed build. No camera, brightness, lock, display-sleep, or ear movement was actuated by these test programs.

## Primary references

- [Apple: What's new in Core Motion, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10179/) describes headphone connection callbacks and Automatic Ear Detection. The callbacks expose no removal reason.
- [Hammerspoon's IOBluetooth implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/battery/libbattery.m) corroborates the legacy per-ear selector convention: zero means in-ear, and primary side 1 means left. It does not guarantee those private fields work on current hardware/macOS.
