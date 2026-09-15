# Privacy Policy

Effective date: September 14, 2026

AirVeil is developed by **ShivHax-YT**, an individual developer based in Nevada, United States. This notice explains information used by the AirVeil macOS app and information you choose to send to the developer. Privacy contact: [shivhax@gmail.com](mailto:shivhax@gmail.com). Developer profile: [ShivHax-YT on GitHub](https://github.com/ShivHax-YT).

## At a glance

AirVeil is a local macOS app that uses AirPods head motion to control a desktop blur effect. Optional camera checks help align head direction and estimate whether the foreground seat is occupied.

- AirVeil processes desktop frames, camera images, and head motion on your Mac. The app does not upload them or save image, video, or audio recordings.
- Some settings and numeric configuration records are saved locally, including camera configuration and a record used to restore display brightness.
- AirVeil has no account system, advertisements, analytics SDK, cloud inference, or automatic diagnostic upload.
- An explicitly enabled diagnostic mode can save a local text-based status file. That file is separate from normal operation.

## Information AirVeil uses

**Desktop frames and display information.** AirVeil uses screen pixels and display/window information supplied by macOS to render live blur on selected displays and exclude its overlay windows. Frames are processed in memory and GPU resources. The app saves no screen recording. Selected display identifiers are saved as preferences.

**AirPods motion and connection.** Head direction, source, timing, and interruption/return signals drive head tracking and enabled display-management behavior. These signals do not establish which individual earbud is in an ear. Current readings, short processing buffers, and event counters remain in memory. No movement or wear history is saved during normal operation; optional diagnostics can include current values and counters.

**Camera images and direction checks.** Optional built-in camera checks use face position, estimated head angles, confidence, and lighting to align head direction and show guidance. Images and preview frames remain in memory. Saved camera setup contains the camera identifier, display layout/configuration, calibration values, and revision; it contains no face photograph.

**Foreground-seat geometry.** Face/body position and size help estimate whether the foreground seat remains occupied during an enabled presence check. The seat reference and current occupancy estimate remain in memory for the app session. They are not saved as preferences.

**Display brightness.** A local recovery record stores the display identifier, original and applied brightness, any pending target, and its creation time. This lets AirVeil recover brightness after an interrupted operation.

**Settings and setup progress.** Effect, energy, and feature preferences, selected displays, tutorial completion, and permission-setup progress are saved locally. Permission setup records which explanations were reviewed and whether you continued with or without each feature. These records do not replace macOS permission decisions and are not sent to the developer.

**Operational state.** Current pointer location, the pause shortcut, session/display state, Low Power Mode, and thermal state support notch controls, pausing, and capture cadence. AirVeil does not record typed keys or a pointer-location history. Optional diagnostics can include operational counters and status.

Screen frames may contain information displayed by other apps, and camera images may include other people in view. Local processing does not make that content non-sensitive. Use camera features with appropriate permission in shared spaces.

AirVeil detects geometric features and occupancy. It does not compare faces to identify a person, create a face-recognition identity template, authenticate a user, or unlock the Mac. Blur and presence estimates can be wrong and do not guarantee that screen content is unreadable to others.

## Camera and device choices

Camera assistance starts disabled unless enabled during setup or previously enabled. The app requests macOS camera permission through an explicit access action. Once enabled and configured, direction checks may run automatically after relevant AirPods interruptions and returns; they do not require a new permission prompt for every check. A direction check stops after success, cancellation, or its time limit.

If removal-related presence checking is enabled, the built-in camera can stay active while AirPods are removed to assess the foreground seat. This is separate from a brief direction check. Disabling camera assistance stops camera features. Closing or hiding Settings alone does not turn off enabled background features.

With automatic display management, camera assistance, and seated dimming enabled together, the seat check distinguishes seated dimming from confirmed-absence display sleep; an unavailable or uncertain check does not request sleep. If automatic display management remains enabled while camera assistance or seated dimming is off, sustained headphone-motion loss can request display sleep without a camera check. Disable automatic display management separately if you do not want that behavior.

AirVeil explains camera, screen-capture, and head-tracking access during setup and lets you continue without each feature. A head-tracking permission request may briefly start a motion session to obtain the macOS decision. Camera and desktop-capture setup do not start a live camera check or desktop effect merely to read a policy.

macOS controls access to the camera, screen capture, and motion. You can review or revoke available permissions in **System Settings → Privacy & Security**. Permission names and available controls depend on your macOS version. Revoking access prevents the corresponding feature from working. The screen-capture permission's name may mention audio, but AirVeil's capture configuration disables audio. [Apple's screen-capture permission guidance](https://support.apple.com/en-gb/guide/mac-help/mchl592e5686/mac)

Use AirVeil's settings to disable automatic display management or camera assistance. **Pause & Clear Screen** cancels the current effect and pending camera/removal work; it does not permanently switch off the saved automatic-display-management preference. Quit AirVeil to stop its running features.

## Local storage and retention

AirVeil uses local macOS preferences associated with `com.shivhax.airveil`. Ordinary preferences remain until replaced or removed. Camera setup remains across launches and is replaced when you set up a new center. **Disabling camera assistance or choosing Reset defaults does not delete the saved camera setup record.** Reset defaults also does not revoke macOS permissions or erase tutorial and permission-setup records.

The session-only seat reference is discarded when AirVeil quits, camera assistance is disabled, defaults are reset, or a display-layout change invalidates it. Processing buffers are released or replaced as their work ends; this is not a promise of forensic secure erasure from operating-system memory or storage.

The brightness recovery record is cleared after successful recovery or when AirVeil determines it no longer owns the brightness setting. It can remain across a crash, interrupted restoration, or inactive session so that restoration can be attempted later. Restore your brightness and quit AirVeil normally before manually removing its preferences; deleting a pending recovery record can prevent that recovery.

Uninstalling the application may leave preferences and user-created diagnostic files behind. This version has no complete in-app data-erasure control. The **Cookies & Local Storage** notice in AirVeil's footer explains the retained categories and controls. Backups, device management, operating-system caches, and files you copy are controlled separately by you, your administrator, or the relevant software.

## Optional diagnostics and support

Launching AirVeil with its explicit `--diagnostics` option writes a JSON status snapshot to the specified file. While enabled, the snapshot is replaced approximately every half-second. It can include build and timestamp, settings, current heading, sensor freshness and sample rate, device-capability results, camera/presence/display states, event counters, and error details supplied by macOS. It does not contain screen frames, camera images, audio, or a face-recognition template.

AirVeil does not automatically send that file anywhere. It remains where it was saved until you remove it; a location you synchronize or back up can create additional copies. Inspect a diagnostic file before sharing it because operational details and error messages may be sensitive.

If you email the developer, the developer receives your email address, message, and any attachments you choose to include. That information is used to respond, investigate the reported problem, and handle follow-up or legal obligations. Relevant correspondence is retained while needed for those purposes; you may request review, correction, or deletion at the contact above. There is no support-upload or automatic email-retention feature inside the app. Public GitHub posts may be visible to others, so do not post private screen content or sensitive diagnostic files there.

The contact address uses Gmail. Email you send is handled by email providers, including Google under its [Privacy Policy](https://policies.google.com/privacy). Support is handled by the developer in the United States, and external service providers may process information in other countries under their own arrangements. This separate communication does not give the developer remote access to information on your Mac.

## Network services and third parties

The audited app contains no network client or server, automatic update service, advertising integration, or analytics SDK. Its device features use macOS frameworks. This statement concerns AirVeil's own code; macOS, your browser, security software, backups, and device-management services have their own behavior and privacy controls.

Downloading AirVeil from GitHub, visiting its repository, or choosing to communicate through GitHub uses GitHub's service. GitHub may process account, connection, and website-usage information under its own [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) and [cookie policy](https://docs.github.com/en/site-policy/privacy-policies/github-cookies). Those website practices are separate from the installed app's local processing.

AirVeil's local features do not sell personal information, send data for targeted advertising, combine activity across other apps or websites for advertising, or transmit user data for model training. The developer does not sell information provided for AirVeil support. The app has no browser-based Do Not Track or Global Privacy Control handling because it has no embedded browser or advertising-data transfer. This does not describe the behavior of websites you visit separately.

## Your rights and questions

You control the local settings, permissions, and diagnostic files described above. The developer cannot remotely read, export, or erase data that exists only on your Mac through the current app.

Depending on the law that applies, you may also have rights concerning access, correction, deletion, restriction, objection, portability, withdrawal of consent, or a complaint to a privacy regulator. Use the privacy contact above for questions or requests concerning information held by the developer. These rights and their limits depend on the circumstances; this notice does not waive them.

**Nevada requests.** Nevada residents may email [shivhax@gmail.com](mailto:shivhax@gmail.com) to submit a privacy request or direct the developer not to sell covered information. This is the designated request address. The developer may ask for information reasonably needed to verify a request and will respond within the period required by applicable law. AirVeil does not currently sell that information. The developer cannot provide local sensor records that the app never sends to the developer.

## Changes to this notice

This notice is bundled with AirVeil and available from its legal footer without opening a website. Its effective date identifies this version. Material changes will be described in release notes and the bundled notice before the changed practice begins, with any additional choice or permission required by applicable law. A policy update alone does not authorize new data access or sharing.
