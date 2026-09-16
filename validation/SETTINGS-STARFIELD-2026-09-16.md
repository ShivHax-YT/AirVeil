# Settings starfield follow-up — 16 September 2026

## Saved implementation

Settings shares the Permissions starfield with a dark appearance and native cards. Meteor placement is selected per surface: Permissions retains its original clear header band; Settings uses its own header band above the cards. No notch source changed.

Restored actual window-occlusion gating. The earlier assertion that an empty occlusion state should be treated as visible was not established. A new native cover/uncover test proves that ordered-in but fully covered windows stop animation. Settings now forwards the optional diagnostic animation callback, allowing runtime evidence without inferring animation solely from screenshots.

## Current verification

- `build/resume-build.log`: release build completed successfully.
- `build/tour-resume.log`: exit 0; 64 tour renders with target visibility checks, 20 settings-tab renders, and eight energy renders. The earlier compact-camera failure did not recur.
- `build/preview-resume.log`: exit 0; SwiftUI simulation updates, callback isolation, Center, model-driven preview, and hide/show redraw recovery passed. Installed accessibility also accepted slider value 25 and Center restored zero; this is not a pointer-drag test.
- `build/starfield-resume.log`: exit 0; visible inactive animation, fully covered pause, uncover resume, Reduce Motion static pixels, hidden pause, reopen, close, and all six full Permissions stages passed. The harness waits for actual inactivity rather than assuming a fixed delay establishes it.
- Installed and built executables have matching SHA-256 `b1a794f404049bec6d6757c7eb3978d443c50fcbe53b4ec8cee376e18a58d404`; strict signature verification passed. The previous installed app is preserved under `build/settings-resume-backup.*`.
- Installed Settings diagnostics showed the animation counter advance from 92 to 118 while permission setup was inactive. Blur was disabled and the camera was off. `build/resume-live.json` is a mutable local diagnostic, not physical acceptance evidence.

This local follow-up still carries version 0.15.0/build 31. Its executable hash distinguishes it from the historical build-31 package. No new release was published.

## Remaining acceptance

### Later live follow-up

Restoring the window via Window > AirVeil recovered full-size capture. Permissions and the tutorial rendered normally. Fullscreen entry rendered the full tutorial, and a clean restart restored the ordinary Settings window. A live Settings screenshot showed the meteor entirely in the header gap above the preview card.

Window > Move & Resize > Top Left made pointer targeting work: an actual preview slider drag changed the angle to +31.9135 degrees with matching direction text; Center restored zero. Earlier drag attempts failed in Computer Use with noWindowsAvailable/windowNotFoundAtPosition. The compact live layout also exposed a frame/content minimum mismatch: NSWindow.minSize included the title bar, reducing the available content below SwiftUI's 740×660 minimum. Changed it to contentMinSize. Twelve native window checks pass (`build/window-final.log`), including actual minimum-frame content geometry.

The normal preview pointer drag and Settings meteor placement are now verified. A pointer drag inside the tutorial, installed corrected minimum-size layout, and complete Space/fullscreen navigation remain open. Capture still intermittently reports -3811/-3812. The user has now agreed to wear AirPods for physical checks; awaiting confirmation that both are inserted before starting the hardware sequence.

The minimum-size fix was built and installed successfully (`build/window-fix-build.log`); strict signature verification passed and installed/build executable SHA-256 matches `5328b9b01d5ed0ff1964567306103e4e935965dc1bac5dc5934e1da083969eeb`. This supersedes the earlier executable hash above. The previous installed app is saved under `build/minimum-size-backup.*`. The first live capture after installation again returned -3811, so the installed minimum-size interaction is not claimed from the geometry test alone.

Live Computer Use could inspect Settings accessibility, but subsequent screen and accessibility captures failed with ScreenCaptureKit error -3811 (audio/video capture failure). Manual tutorial dragging, live minimum-size interaction, final visual confirmation of the Settings meteor band, and Space/fullscreen interaction remain unverified. Generated renders and diagnostic ticks do not establish these live interactions.

Automatic departure/lock, low-light recovery, and repeated brightness recovery in both AirPods-return/unlock orders require a wearer and physical tests. Per-ear detection while the other AirPod continues sending motion is a documented platform limitation. No Hi/voice/wake-word feature is implemented.

The previous conversation's blanket statements that every non-AirPods test was finished and only hardware acceptance remained were too broad. The live UI items above remain open.
