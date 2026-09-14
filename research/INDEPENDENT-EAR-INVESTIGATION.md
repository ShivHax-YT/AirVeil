# Independent AirPod removal investigation

September 14, 2026. The user reported that removing the AirPod which is not supplying motion still fails to trigger the removal behavior in AirVeil 0.11.0.

## Confirmed software defect and fix

`SystemAirPodsWearReader` queries Bluetooth on a background queue and returns the latest cached, timestamped result to the motion service. If a query takes longer than the 250 ms polling interval, the consumer can see:

`new A → cached A → new B → cached B`

`AirPodsWearEvidence.update` previously reset its candidate stability evidence whenever it saw a duplicate receipt timestamp. That could prevent a wear baseline, removal, or reinsertion from ever being confirmed even when the framework was returning useful values.

The fix ignores still-fresh duplicate or older cached receipts without creating another observation or clearing the preceding candidate. Invalid, missing, future, and genuinely stale readings retain the existing uncertainty behavior. The added regression tests exercise the actual cached-result pattern for all three transitions and verify that stale evidence still breaks the confirmation interval.

Verification: **26 pure wear-evidence assertions pass**, compiled with the macOS 26.5 SDK and Swift 6. This proves the state-machine correction, not physical per-ear hardware delivery.

## Read-only runtime findings

The following probes changed no brightness, camera, lock, Bluetooth settings, pairing, or connection state, and did not scan for devices:

- Legacy IOBluetooth enumeration returned five paired objects, zero connected objects, and one paired Apple object reporting ear-detection support. That object's cached values were `multiBattery=0`, `earDetection=0`, `primarySide=0`, and `primaryInEar=secondaryInEar=0`. Getter return types were the expected boolean/byte types.
- A distinct legacy test initialized NSApplication, registered a passive public connection-notification observer, and ran the main run loop for ten seconds. The same counts and values remained; no connection callback arrived.
- The CLI's public `CBManager.authorization` returned `AllowedAlways`. This describes that process's authorization and does not substitute for the installed app's permission context.
- Runtime inspection found modern `CBDevice` placement getters and `BluetoothDevice.inEarStatusPrimary:secondary:`. Read-only BluetoothManager connected enumeration was empty. Private CBController activation and device enumeration each returned `CBErrorDomain -71168`; no modern ear-state reading was obtained. The error's precise cause was not established, so it is not labelled an entitlement or permission denial here.
- The signed app's diagnostic launch, with automatic removal off, returned the same legacy counts and values. **At that time its motion diagnostics also showed no sensor, zero samples per second, and stale motion.**

An earlier UI view showed approximately 50 samples per second from the right AirPod, but it was not simultaneous with the later Bluetooth probe. The headphones subsequently became disconnected. Comparing these different moments cannot prove that the legacy reader fails while the AirPods are worn.

The production reader now exposes an anonymous `diagnosticStatus`: counts and capability/ear fields only. It includes no device names, addresses, serial numbers, selection tokens, or accumulated history. Root integration forwards this through the diagnostic-only app path so a future test can collect motion freshness and per-ear metadata from the same running process at the same time.

## API evidence and constraints

Apple's headphone motion API delivers one bud's motion at a time. Its source location can change for multiple reasons, and Automatic Ear Detection affects public connect/disconnect events. A source switch alone therefore cannot prove independent ear removal. [Apple WWDC23 Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179/)

The current legacy reader follows the private fields used by Hammerspoon: `primaryBud`, `primaryInEar`, and `secondaryInEar`, with zero interpreted as in-ear and primary side 1 as left. This is a compatibility implementation, not a supported Apple per-ear contract. [Hammerspoon source](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/battery/libbattery.m)

AudioAccessoryKit is not an alternative Mac reader: Apple's documentation limits it to iPhone/iPad accessory integration, and the local macOS 26.5 Swift interface explicitly marks `AccessoryControlDevice` unavailable on macOS. [Apple AudioAccessoryKit](https://developer.apple.com/documentation/audioaccessorykit)

## What remains unproven

No synchronous worn-headset sample has yet established whether this AirPods model/firmware supplies the legacy fields, what exact values are returned for each side, or whether the duplicate-cache defect explains the reported physical failure. The reader's eligibility or value mapping was not loosened merely to make offline cached zeros look valid.

The next hardware check needs a single synchronized record of fresh motion plus anonymous per-ear metadata while both buds are worn, after removing the nonstreaming bud, and after reinserting it. It can run with automatic dimming and locking disabled. The user's pending clarification determines whether a single removed bud should dim a seated user's screen or only arm departure detection; detection evidence itself remains independent of that policy choice.

## Additional primary-source review: modern reader alternatives

The bounded source review found **no verified macOS implementation of an already-connected, scan-free CBDevice placement feed** suitable for replacing the current reader. This is a research result, not a claim that every possible implementation is unsupported. No extra device probes or changes to Bluetooth state were made for this review.

Runtime headers from iOS 18 expose the exact private candidates: `CBController.activateWithCompletion:` followed by `getDevicesWithFlags:completionHandler:`; `CBDiscovery.devicesWithDiscoveryFlags:error:` for a snapshot; and `CBDiscovery.deviceFoundHandler` / `deviceLostHandler` for updates. They also expose `needsBLEScan`, so enabling a discovery object with guessed flags cannot be assumed to be scan-free. The inspected declarations provide neither safe discovery-flag constants nor proof that a third-party Mac process can use this service. [CBController declarations](https://github.com/qingralf/iOS18-Runtime-Headers/blob/main/Frameworks/CoreBluetooth.framework/CBController.h), [CBDiscovery declarations](https://github.com/qingralf/iOS18-Runtime-Headers/blob/main/Frameworks/CoreBluetooth.framework/CBDiscovery.h)

The alternative private `BluetoothDevice` API has a **boolean success result** for `inEarStatusPrimary:(int *)primary secondary:(int *)secondary`, and a separate `primaryBudSide:(int *)side` method returning an integer result. Those are output-pointer methods, not the legacy byte getters. The source does not establish placement or side enum mappings for this Mac, and the legacy zero-is-in-ear mapping must not be copied to `CBDevice.primaryPlacement` merely because both represent wear. [BluetoothDevice declarations](https://github.com/qingralf/iOS18-Runtime-Headers/blob/main/PrivateFrameworks/BluetoothManager.framework/BluetoothDevice.h)

The open-source macOS app NoiseBuddy uses the legacy `IOBluetoothDevice.pairedDevices()` path plus passive `register(forConnectNotifications:selector:)` observation. It does not demonstrate modern independent wear delivery. A newer macOS project, Earshot, retains a private BluetoothManager probe that reports zero devices after ad-hoc signing and a run-loop wait. Its feasibility note speculates about Developer ID or a private entitlement; **that speculation does not explain AirVeil's `-71168` error**, and no precise required entitlement was established by this review. [NoiseBuddy implementation](https://github.com/insidegui/NoiseBuddy/blob/master/NoiseCore/Source/NCBTListeningModeController.swift), [Earshot probe](https://github.com/suryacks/Earshot/blob/main/research/probes/bluetoothmanager-probe.m), [Earshot feasibility note](https://github.com/suryacks/Earshot/blob/main/docs/FEASIBILITY.md)

Earshot instead parses nearby BLE advertisements. Its own protocol note marks the in-ear/primary-bud bits unconfirmed; its device registry matches advertisements by model and signal strength. That is not adequate ownership evidence for an automatic screen-lock decision, and the feed requires scanning. It is therefore not a substitute within this investigation's connected-device-only boundary. [Earshot protocol limits](https://github.com/suryacks/Earshot/blob/main/docs/PROTOCOL.md), [Earshot registry](https://github.com/suryacks/Earshot/blob/main/Sources/EarshotKit/Devices/DeviceRegistry.swift)

Apple documents `com.apple.security.device.bluetooth` as the App Sandbox Bluetooth hardware entitlement; it does not document this as authorization for those private controllers. Public `retrieveConnectedPeripherals(withServices:)` can enumerate matching system connections, but Apple says the app must establish its own local connection before using those peripherals. It neither exposes AirPods placement nor proves a passive wear-notification route. [Apple Bluetooth entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth), [Apple connected peripheral retrieval](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:))

Recommendation: first collect the simultaneous motion/legacy-wear record described above. Keep unknown data unknown; do not infer two-ear wear from one motion stream, map undocumented placement values without a fixture, activate discovery with guessed flags, or add speculative private entitlements. Consider another backend only after evidence shows why the existing source fails and a connected-device ownership and freshness contract can be demonstrated.
