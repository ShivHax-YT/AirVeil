# Settings, wear prompt, and wake recovery — builds 24–26

## Scope and status

This records **0.15.0 builds 24–25** and the subsequent live-dial refinement on 15 September 2026. Build 24 passed the full regression suite and focused native UI checks, then was packaged, installed, verified, and launched through LaunchServices. The wearer confirmed that Turn off feature restored brightness and extinguished the green camera light. Installed build 25 passed the physical Settings wait/alignment/automatic-blur sequence. The wearer confirmed that Sync head moves the illustration, then requested that its arc marker and large degree readout move with it; that refinement is in progress. Repeated post-lock brightness recovery remains pending.

| Change | Current behavior | Remaining installed or physical acceptance |
|---|---|---|
| Restore brightness after departure and lock | Brightness reads reject an asleep display. A restore interrupted by another lock/sleep retains the original journal until awake recovery verifies it. Cleanup must finish before heading recovery. | Repeat both return orders below; confirm the actual panel returns to its original brightness each time. |
| Organize Settings | Preview, Tracking, Displays, Appearance, and Power use native tabs. Each of the 16 tour steps selects its tab and scrolls to its real control. Enable/Pause remains in the header. | Installed tabs and the first three tour steps were inspected. Remaining acceptance includes the complete live tour and minimum-window interactions. |
| Sync head | The explicit Appearance action requests camera/AirPods alignment, then displays signed live yaw independently of onset selection and blur inversion. It does not edit onset angles or independently start desktop capture. | Build 26 is wearer-confirmed: the head, moving arc marker, and large degree readout follow correctly. Stop sync returned to the saved 11°/13° onset controls in the installed UI. |
| Seated wear prompt and off control | Missing motion during seated monitoring shows animated AirPods Pro artwork and “Wear AirPods to continue blurring.” “Turn off feature” cancels blur and camera work, restores owned brightness, and persists an automatic-check pause. | One live off action is wearer-confirmed for brightness restoration and camera-light shutdown. Animation acceptance, persistence after relaunch, and explicit re-enable remain pending. |
| Enable while waiting for AirPods | Enable queues a wait without starting the camera. Fresh motion then requests real camera alignment; valid alignment permits blur to start automatically. Failure or cancellation leaves blur off. | Build 25's full Settings Enable path is wearer-confirmed and agrees with runtime evidence. The notch entry point and interruption variants remain separate acceptance items. |

## Automated evidence

These checks use generated images and injected device, permission, brightness, capture, and display-sleep boundaries. They do not change the user's hardware or establish physical head direction.

`bash scripts/test.sh` completed successfully, with its final output retained in `build/build24-regression.log`. It includes **334 AppModel, 129 camera coordinator, 132 brightness, 91 removal coordinator, and 390 onset/live-head checks**, plus the existing permission, motion, fusion, presence, energy, pointer geometry, and actual Metal GPU suites. GPU checks passed at 1× and 2× for masks, transparent/opaque endpoints, direction, frame replacement, rendering demand, and lifecycle boundaries. This is generated-image rendering, not live desktop capture.

- **334 AppModel/removal-coordinator lifecycle assertions** passed in `build/appmodel-wake-wear-24.log`. Cases include three repeated cycles for each unlock/reinsert order, wait → alignment → automatic enable, cancel during wait/alignment, persistent feature pause, pending-brightness retry while paused, explicit Set center/Refresh direction after feature-off, and signed Sync head updates without onset edits.
- **129 camera coordinator/service/fusion checks** passed in `build/camera-coordinator-late-permission-2026-09-15.log`. A delayed permission approval delivered after cancellation cannot restart assistance, camera capture, or Face light.
- **64 native tour renders, 20 normal Settings-tab renders, and 8 energy renders** passed in `build/settings-tabs-render.log`. The harness checks the selected tab and highlighted target's visibility, with onset preferences unchanged.
- **16 onset layouts** were rendered in `build/settings-head-render.log`, covering unsynced, signed live, and pending presentations. This checks labels and control layout; it does not establish the live head's orientation.
- **18 notch geometry and 114 native controller lifecycle checks** passed in `build/notch-wear-wait-2026-09-15.log`, followed by 31 rendered states, two identical Reduce Motion AirPods glyphs, and two Face light renders. The fixtures cover wear-prompt priority, cancellation, handoff to the existing camera check, and delayed retraction.

The final control review identified a paused camera session blocking explicit Set center/Refresh direction after feature-off. Those actions now re-enable the camera session after their prerequisites pass; both the focused lifecycle run and full regression include the correction. These results precede the installed observations below.

### Rendering limits

Offscreen native rendering omits some native glass and can omit or misplace nonzero `rotation3DEffect` layers. Static layout assertions and generated artwork are useful evidence, but do not prove the full live head/notch animation composition. Installed screenshots subsequently showed the Appearance head correctly centered, without the offscreen artifact. Live direction and moving notch composition still require wearer feedback. No energy or battery savings are measured here.

## Required physical sequence

Keep the existing seated-dimming target. Establish fresh AirPods motion and a successful centered camera check before each removal episode. Record only aggregate status and numeric brightness state; do not record camera images or credentials.

1. **Return before unlock:** remove both AirPods while seated and confirm dimming without lock. Leave the seat until departure requests display sleep/lock. Reinsert both before unlocking, then unlock normally. Confirm original brightness returns before the heading check resumes. Complete alignment and repeat the whole cycle at least three times.
2. **Unlock before return:** repeat departure, then unlock while the AirPods remain out. Return them after unlocking. Confirm original brightness returns and alignment can finish. Repeat at least three times, including a short awake interval with the buds still out.
3. **Turn off feature:** while seated and dimmed with buds out, use the notch button. Confirm brightness returns, blur clears, and the camera stops. Reinsert/remove again and relaunch; automatic checks must remain paused. Use Enable blur explicitly and confirm the workflow can start again. Also exercise explicit Set center and Refresh direction after feature-off.
4. **Enable without motion:** with blur off and both buds out, choose Enable blur from Settings and repeat from the notch. Confirm the waiting artwork appears with the camera off. Wear both, face forward for alignment, and verify blur starts afterward. Cancel a waiting attempt and an in-progress check; neither may start later.
5. **Sync head and Settings:** in Appearance, record onset values, press Sync head, complete the real check, and turn left/right. Confirm the illustration matches physical direction without editing thresholds. Verify Stop sync, switching tabs, minimizing, and closing Settings. Exercise all tour controls, especially the simulated-turn slider and onset controls, at the minimum window size.

If restoration still fails, inspect explicit local diagnostics: `brightnessOriginal`, `brightnessLastApplied`, `brightnessPendingTarget`, `brightnessRestorePending`, presence phase, and session state. A live driver value differing from AirVeil's applied level can still be interpreted as a manual brightness override; automated wake ordering cannot rule out that hardware behavior.

## Verified build and installed observations

The release operator verified the build 24 DMG and installed bundle, then launched `/Applications/AirVeil.app` normally through LaunchServices. Fresh diagnostics reported build 24. The retained machine-readable record is `build/validation/release-0.15.0-build24.json`:

- Version **0.15.0**, build **24**.
- DMG SHA-256: `045b8f23872c9555cf4c98474fc439a79460a0fff7da1f77439578a00384a425`.
- Executable SHA-256: `35930e7a0476a2a1fa3afd3aaaae697e98d35955d6a0e22b5dd574bb0fb9d36d`.
- Installed executable matches the DMG; all bundled policies match source; developer previews are excluded; strict signature verification passed.

Native computer-control screenshots succeeded for the installed Settings. They showed the five-tab toolbar, visible Tracking, Displays, Power, and Appearance content, and a centered onset head without the offscreen rendering artifact. The live tour moved from Preview step 1 to step 2. Its real slider was incremented to 12°, verified through accessibility, then reset with Center. Continuing to step 3 selected Tracking. The tour was then closed. This is direct installed interaction evidence for those steps, not a complete live tour pass.

The wearer confirmed both AirPods were out. Runtime observation then reported foreground presence, an active presence camera, built-in display dimming at the retained **1%** target, and `wearAirPodsPrompt == true`. After the wearer clicked **Turn off feature**, the retained snapshot `build/validation/build24-seated-after-off.json` reported:

- `automaticFeaturesPaused == true`, `wearAirPodsPrompt == false`, and blur disabled.
- Both direction and presence cameras stopped; presence phase returned to idle.
- `displayDimmed == false`, brightness status “Original display brightness restored,” no pending restoration, and no remaining brightness journal values.

The wearer subsequently replied **“Both worked”** when asked whether Turn off feature restored brightness and turned off the green camera light. Those two outcomes pass for this physical episode and agree with the retained cleanup snapshot. This does not establish animation acceptance, persistence across relaunch, repeated post-lock restoration, actual left/right Sync head direction, or automatic enable after alignment.

Fresh motion later returned and the automatic-check pause state later cleared between tests without a fully attributed action sequence. That observation establishes neither a persistence failure nor a persistence pass. The next no-motion Enable test therefore started from a newly confirmed AirPods state in build 25 below.

## Build 25 status-wording follow-up

Build 25 replaces misleading asleep/inactive wording when direction checks are deliberately paused, and refreshes guidance on reactivation. It does not start a camera check itself. The focused coordinator suite passed **142 checks**, retained in `build/camera-coordinator-neutral-pause-status-2026-09-15.log`.

The correction is included in the now installed build 25. The build 24 installer is archived under `build/releases/iterations/build-24/`. The retained build 25 identity record is `build/validation/release-0.15.0-build25.json`:

- Version **0.15.0**, build **25**.
- DMG SHA-256: `f404342e1a685649016e3ec1567bebd6ac5c2c992d420c6511eecfc7ed57603c`.
- Executable SHA-256: `ea69c9671d4c06e441dbb9effd3cf7539e84e1624eb920d3e798344fac596ebd`.
- Installed executable matches the DMG; all bundled policies match source; developer previews are excluded; strict signature verification passed.

### Installed no-motion Enable wait

The wearer confirmed both AirPods were out before **Enable blur** was clicked in Settings. The retained snapshot `build/validation/build25-waiting-no-motion.json` reports build 25, no fresh motion, and the wear prompt visible. Both the direction and presence cameras are off; blur and desktop capture are off; automatic checks are enabled; no brightness restoration is pending. This verifies the first, waiting portion of the explicit Enable flow from a confirmed physical starting state.

The wearer then put both AirPods back in, completed the camera check, and reported **“Yes, blur started automatically.”** The retained `build/validation/build25-auto-enable-confirmed.json` agrees: fresh motion and valid tracking, alignment revision 1, live blur and desktop capture running, the wear prompt hidden, and both cameras stopped. Onset preferences remained 11° left and 13° right. The bounded 100-second status collection `build/validation/build25-wait-to-enable.jsonl` also completed. This physical Settings Enable path passes; the notch entry point and interruption variants remain separate acceptance items.

Before Sync head could be opened, computer control reported the Mac locked. The retained `build/validation/build25-unplanned-lock.json` records one display-sleep request, no active cameras/capture, and no pending brightness restoration. The wearer's exact removal/departure sequence was not yet known, so this is not counted as either a post-lock brightness pass or a failure. Later diagnostics showed the seated target at 23%, reflecting a changed preference; the test operator did not change that value.

### Physical head sync and requested dial refinement

The wearer confirmed that the illustrated head moves, then requested that the arc slider and large degree readout follow the live angle too. The bounded `build/validation/build25-head-sync.jsonl` observed yaw from approximately -56.9° to +61.3° with both onset settings fixed at 11° and 13°. A live native screenshot showed the centered head and all surrounding labels in place. This confirms head telemetry and movement, but the static onset marker/readout did not satisfy the expanded user request. Build 26 is reserved for the live dial refinement; it is not installed at this checkpoint. The first controlled return-before-unlock brightness test is now in progress.

### Controlled post-lock failure reproduced

The wearer completed the first return-before-unlock cycle with brightness controls untouched and reported **“It stayed dim.”** The retained `build/validation/build25-return-before-unlock-cycle1.jsonl` establishes the failure path: baseline 0.6252058744430542, applied dim 0.23000000417232513, then an intact journal in the suspended phase. On wake, build 25 cleared that journal with “Brightness was adjusted manually. Your setting was kept.” The original asleep-read and revision guards therefore did not fix the physical failure. Build 26 is being updated to retain dim ownership across explicit suspension and restore that baseline despite a different wake reading, while preserving normal awake manual overrides. No post-lock brightness pass is claimed.

## Build 26 correction checkpoint

The live dial now has separate editing, waiting, and tracking presentations. While synced, signed yaw drives its head, marker, arc fill, and large readout; the marker is limited to the ±60° arc while the actual readout and limit note remain honest. Waiting hides the marker and shows no numeric angle. Both pointer and accessibility edits are absent in live/waiting modes, preserving the two onset settings. The dial passed 2,534 focused checks (`build/onset-live-dial-2026-09-15.log`) and 108 native layout/rendered-arc checks across 40 fixtures (`build/onset-live-dial-render-2026-09-15.log`).

The brightness journal now carries a backward-compatible optional wake-restoration flag. Explicit suspension latches it durably, including while a dim write is outstanding. Awake restoration of that owned dim restores the original baseline rather than interpreting a different wake reading as a manual override. Normal uninterrupted-awake overrides remain respected. The direct dimming suite passed 243 checks (`build/display-dimming-wake-ownership-2026-09-15.log`), including changed wake values, repeated return orders, legacy decoding, relaunch, failed verification, retries, and late locks. New explicit local diagnostics retain the restoration read/decision and Mac session state.

The full regression suite completed successfully (`build/build26-regression.log`), including 334 AppModel, 142 camera coordinator, 243 brightness, 91 removal coordinator, and 2,534 dial checks plus existing GPU/motion/presence/energy suites. Build 26 was then packaged, strictly signature-verified, installed with a backup of build 25, and launched through LaunchServices. Physical acceptance remains pending.

Build 26 artifact evidence is retained in `build/validation/release-0.15.0-build26.json`:

- DMG SHA-256: `57065f97d8ba730bc133ae3602d69ea96e718f04bf66300a454979cdf0e5290c`.
- Executable SHA-256: `e78796a28d2eb9e9b5e73f6f21efe407e661f6f6b82b77043c378940c19781df`.
- Installed executable matches the DMG, bundled policies match source, developer previews are excluded, and strict signature verification passed.

Fresh build 26 diagnostics show the new session state and restoration decision fields. Sync head was started from the installed Appearance tab; it is waiting for the wearer to check the new marker/readout before the next controlled brightness cycle.

### Build 26 live dial accepted

The wearer answered **“Yes, the marker and degrees follow correctly.”** A live native capture showed a rightward green arc marker and approximately -35° readout together, with the head and surrounding content positioned normally. After the wearer stopped sync, the installed UI returned to onset editing with Left 11° and Right 13° intact. The revised live dial is physically accepted. A new controlled return-before-unlock brightness cycle is now being collected in `build/validation/build26-return-before-unlock-cycle1.jsonl`; its result remains pending.
