# AirPods removal and return repair — 14 September 2026

## Current revision: both-AirPods removal

The user subsequently narrowed this feature to removing both AirPods. This revision supersedes the per-ear implementation and the seated-no-dim connection fallback described below. The earlier observations remain useful diagnostic evidence.

- Runtime detection now uses public Core Motion only. The private IOBluetooth reader and its runtime dependency were removed; AirVeil does not request Bluetooth access. Head Tracking uses Motion permission, local presence uses Camera permission, and the desktop effect uses Screen Recording permission.
- Advancing fresh motion must span at least 0.75 seconds before detection arms. Freshness expires after 0.65 seconds; a further 0.35-second loss grace produces one removal episode. The application then applies its existing 1.5-second cancellation window before taking an action. A public disconnect starts loss timing immediately, while a silent stopped stream is also detected.
- Continuous motion from one AirPod, including a source handoff, produces no removal episode. This does not inspect or claim to identify individual ears. A sustained connection failure or device handoff can resemble both-AirPods removal; the public API supplies no reason code. Automatic Ear Detection must stay on for normal both-out behavior.
- With camera assistance, seated dimming, and a saved seat enabled, a removal episode starts one local seat check. Confirmed seated presence dims the built-in display to the saved target (default 0%). Confirmed absence requests display sleep. Missing seat geometry or camera uncertainty does not request sleep.
- Presence monitoring continues while seated and dimmed. Two fresh dark frames permit one on-screen light attempt of at most 2.5 seconds. The light stops on a result, failure, cancellation, or deadline. A screen light cannot illuminate a face while hardware brightness is at zero; if presence stays unknown for 8 seconds, AirVeil ends the check and restores its saved brightness instead of treating darkness as absence.
- Fresh returned headphone motion restores saved brightness and stops presence capture before direction recovery. This return can be from one bud; it does not prove both are inserted. The old screen center remains retained and unverified until a fresh camera measurement or explicit Set center. A source switch or raw connection callback alone does not launch a camera check.
- Permission onboarding gates automatic motion and all normal camera/capture entry points. Skipping Head Tracking leaves motion stopped; an explicit tutorial start opens Permissions instead of silently prompting. Lock, sleep, Pause, shutdown, and permission failures preserve existing cancellation and restoration barriers.

Targeted automated validation for this revision: 15 pure wear-policy checks, 51 production motion-reference lifecycle checks, 62 motion-delivery checks, 124 camera-coordinator checks, 278 AppModel/removal integration assertions, 47 removal-presence coordinator checks, and 28 presence capture/light lifecycle checks. Physical providers were injected; these tests did not open the camera or change real brightness, lock state, or device settings.

### Installed physical test: AirVeil 0.15.0, build 20

The user performed the both-AirPods removal/return test and explicitly confirmed that the display dimmed while seated without locking. Anonymous evidence is in `build/validation/both-airpods-0.15.0/live-test.jsonl`; the later snapshot is `build/permission-dimming-live.json`.

- Two separate removal episodes were detected. Each camera seat check reached `present` and dimmed the built-in display to the user's existing **2%** target. The display-sleep request count stayed **0**.
- The first return is recorded with fresh motion, original brightness restored, no pending restore, presence capture stopped, and the automatic direction camera running. The live operator observed restoration before both return checks. The later snapshot confirms two automatic return checks, restored brightness, no idle-sleep assertion, and both cameras off.
- The first direction recovery was interrupted by the second removal while it was still seeking a centered, steady view. The final `Tracking interrupted` status is a motion/reference invalidation message, not the camera timeout message. The later snapshot also contains one rejected 35.4° attitude discontinuity against a 20.1° limit over 20 ms. That is consistent with the deliberate reference-safety cancellation; the appended final snapshot confirms the second restore and return count, but the intervening second-return sequence was not recorded, so the exact jump timing is unknown. A completed second direction alignment is therefore **not** claimed from these records alone. Fresh motion remains available, and an explicit Refresh direction can retry the saved center.

This verifies physical seated dimming and brightness restoration with this setup at 2%. Departed-seat sleep/lock, a physical 0% brightness run, extended darkness recovery, and sustained connection/device-handoff behavior remain untested. Individual-ear identification is outside the selected scope.

## Earlier diagnostic revision (superseded behavior)

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
