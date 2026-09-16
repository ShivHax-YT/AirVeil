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

Live Computer Use could inspect Settings accessibility, but subsequent screen and accessibility captures failed with ScreenCaptureKit error -3811 (audio/video capture failure). Manual tutorial dragging, live minimum-size interaction, final visual confirmation of the Settings meteor band, and Space/fullscreen interaction remain unverified. Generated renders and diagnostic ticks do not establish these live interactions.

Automatic departure/lock, low-light recovery, and repeated brightness recovery in both AirPods-return/unlock orders require a wearer and physical tests. Per-ear detection while the other AirPod continues sending motion is a documented platform limitation. No Hi/voice/wake-word feature is implemented.

The previous conversation's blanket statements that every non-AirPods test was finished and only hardware acceptance remained were too broad. The live UI items above remain open.
