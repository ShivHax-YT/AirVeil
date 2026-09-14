# Apple Edge Light and a centered camera check

Apple's Edge Light is the relevant Mac ring-light feature. This Mac supports it, and AirVeil can use a public API to open Apple's video-effects controls. The public API exposes supported/enabled/active state, but no Edge Light setter. The feasible product action is **Open Edge Light controls**, followed by the wearer enabling Edge Light in Apple's panel. A custom screen light would be a separate feature and should not be substituted silently.

## Verified local support

Read-only inspection on September 13, 2026 found macOS **26.6.2**, build **25G83**, on a **MacBook Air with Apple M5**, model identifier **Mac17,3**. A read-only AVFoundation probe discovered the built-in **MacBook Air Camera** and returned `activeFormat.isEdgeLightSupported == true`. The probe created no capture session, requested no permission, and opened no system UI.

Apple requires Apple silicon and macOS Tahoe 26.2 or later. Edge Light illuminates the display border to provide actual light on the face; for the built-in camera it uses the built-in display. Apple also offers brightness, color-temperature, and automatic low-light controls, with automatic activation limited to Macs introduced in 2024 or later.[^1]

The probe process returned `isEdgeLightEnabled == false` and `isEdgeLightActive == false`. Those results must not be presented as AirVeil's saved setting: they came from a separate process. AirVeil should read the properties in its own active capture context and check the actual configured camera format.

## Public API contract

| Requirement | Supported interface | Constraint |
|---|---|---|
| Detect device/format support | `device.activeFormat.isEdgeLightSupported` | Read-only; macOS 26.2+. |
| Observe the setting | `AVCaptureDevice.isEdgeLightEnabled` | Read-only, key-value observable; macOS 26.2+. |
| Observe whether the border is displayed | `AVCaptureDevice.isEdgeLightActive` | Read-only, key-value observable; macOS 26.2+. |
| Present Apple's controls | `AVCaptureDevice.showSystemUserInterface(.videoEffects)` | macOS 12+; opens the system effects module and returns immediately. |
| Toggle Edge Light or set its brightness automatically | No public setter found in current Apple documentation or installed SDK | The user changes these controls in Apple's interface. |

The getter contracts are stated in Apple's API documentation.[^2][^3][^4] The installed `AVCaptureDevice.h` declares the Edge Light properties as `readonly`, with availability from macOS 26.2, and declares `showSystemUserInterface` from macOS 12.0. A search of the installed SDK's public framework headers and Swift interfaces found no Edge Light setter or brightness/temperature control.[^5]

Apple documents `showSystemUserInterface(.videoEffects)` specifically as a nonblocking way for an application to bring up the appropriate effects module.[^6] This supported API is preferable to an undocumented System Settings URL, private preference modification, or scripted clicks. It does not report a successful toggle; enabled and active state remain separate observations.

The Mac User Guide introduces these effects through an app that captures video, rather than requiring a FaceTime call.[^7] That supports using AirVeil's own authorized AVCapture session as the context. The precise panel appearance for AirVeil remains a UI-verification item; this investigation did not open it or change any settings. No Edge Light-specific opt-in key appears in the inspected SDK category.

## Suggested button behavior

While a low-light camera check is active, display **Open Edge Light controls** with brief supporting text: “Turn on Edge Light in the Video Effects panel.” Its action can use the following public call:

```swift
AVCaptureDevice.showSystemUserInterface(.videoEffects)
```

Gate the Edge Light-specific label and state reads with `#available(macOS 26.2, *)`, and inspect camera-format support. Opening Apple's controls is the completed button action. Do not immediately change the message to “Light is on” merely because the call returned.

Keep the current capture active only within its existing explicit, bounded lifecycle. If the check already ended, the button can explicitly initiate a new bounded camera check and present the controls after capture is ready. Avoid presenting an inactive camera's controls as if they were guaranteed to belong to AirVeil. Opening the panel must neither establish alignment nor silently extend a check indefinitely.

When Edge Light becomes active, let fresh camera observations demonstrate whether conditions improved. Brightness alone does not prove a face is valid or centered. The API's enabled flag also does not establish that the border is visible; use the active flag for that distinction. If the Apple control cannot be used, explain the supported manual path or ordinary front lighting. A separate custom overlay requires an explicit product decision.

## Vision coordinates and the five-degree criterion

The inspected local Vision header specifies:

- `yaw`: radians, positive counterclockwise, within approximately ±π/2.
- `pitch`: radians, positive for nodding down, within ±π/2.
- `roll`: radians, positive counterclockwise, within approximately ±π.
- Missing calculated angles are nil.[^8]

Apple's online documentation identifies yaw with rotation around the y-axis and pitch with rotation around the x-axis.[^9][^10] These contracts identify angular measurements, but the word “counterclockwise” alone does not specify a wearer-left versus mirrored-screen-right label without the viewing convention. Preserve the established headphone axis adapter and independently verify directional UI mapping.

AirVeil's unmirrored `AVCaptureVideoDataOutput` and `.up` request orientation provide a consistent analysis input. Apple states that `isVideoMirrored` controls horizontal reflection and that video-data outputs apply reflection to the actual delivered frames.[^11] The `.up` orientation is the identity orientation, whose encoded pixel origin is top-left.[^12] Vision observation rectangles are a different coordinate representation: normalized image coordinates with a lower-left origin.[^13] Keep those pixel, observation, and mirrored-preview spaces separate.

For a center-facing check, **`abs(yawDegrees) <= 5` is independent of sign**. It can gate neutral camera evidence without asking for a deliberate left/right turn merely to learn camera sign. Once a stationary, fresh, same-epoch AirPods interval is paired with that accepted face observation, establishing that sensor pose as the neutral heading is an architectural option. Directional display feedback still needs its own mapping, and subsequent movement must not redefine that neutral pose.

A five-degree acceptance threshold is a threshold on Vision's estimate, not a documented five-degree physical-accuracy guarantee. The consulted Apple pages do not publish such an error bound. A short check should collect distinct valid observations over a measured time interval; elapsed time alone, preview frames, or a face box centered in the thumbnail cannot prove alignment. The low-light button changes illumination conditions, not these evidence requirements.

## Sources

[^1]: Apple Support, [Use Edge Light to illuminate your face during video calls](https://support.apple.com/en-us/125934), published December 12, 2025; accessed September 13, 2026.
[^2]: Apple Developer Documentation, [AVCaptureDevice.isEdgeLightEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isedgelightenabled), accessed September 13, 2026.
[^3]: Apple Developer Documentation, [AVCaptureDevice.isEdgeLightActive](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isedgelightactive), accessed September 13, 2026.
[^4]: Apple Developer Documentation, [AVCaptureDevice.Format.isEdgeLightSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/isedgelightsupported), accessed through Apple's documentation Markdown representation September 13, 2026.
[^5]: Installed Apple SDK, `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCaptureDevice.h`, lines 2755–2780 and 3966–3987. Read-only local inspection September 13, 2026; compiled read-only getter probe also succeeded on this Mac.
[^6]: Apple Developer Documentation, [AVCaptureDevice.showSystemUserInterface(_:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface(_:)), accessed September 13, 2026.
[^7]: Apple Mac User Guide, [Use the camera on Mac](https://support.apple.com/guide/mac-help/use-the-camera-mchlp2980/mac), macOS Tahoe edition, accessed September 13, 2026.
[^8]: Installed Apple SDK, `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Vision.framework/Headers/VNObservation.h`, lines 106–137; read-only inspection September 13, 2026.
[^9]: Apple Developer Documentation, [VNFaceObservation.yaw](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw), accessed September 13, 2026.
[^10]: Apple Developer Documentation, [VNFaceObservation.pitch](https://developer.apple.com/documentation/vision/vnfaceobservation/pitch), accessed September 13, 2026.
[^11]: Apple Developer Documentation, [AVCaptureConnection.isVideoMirrored](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/isvideomirrored), accessed September 13, 2026.
[^12]: Apple Developer Documentation, [CGImagePropertyOrientation.up](https://developer.apple.com/documentation/imageio/cgimagepropertyorientation/up), accessed September 13, 2026.
[^13]: Apple Developer Documentation, [VNDetectedObjectObservation.boundingBox](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox), accessed September 13, 2026.
