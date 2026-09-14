# Notch direction-check failure recording

Source: `Screen Recording 2026-09-13 at 7.40.56 PM.mov` supplied by the user on 2026-09-13. The actual filename contains a narrow nonbreaking space before `PM`. Duration 73.735 seconds; 2940 × 1912; approximately 49.6 fps; no audio stream. This is an observation report of the supplied recording, not a live hardware test.

## Outcome

Three consecutive attempts end with **“Try the direction check again”**. None reaches a successful center confirmation. Each attempt lasts about 20 seconds. The camera preview is visibly live; the user turns their head and changes distance. The strongest repeated symptom is partial progress disappearing when the status switches to **“Waiting for steady AirPods motion.”**

## Timeline

Times are approximate (within about 0.5 seconds), from inspection and text recognition of notch crops sampled with FFmpeg `fps=2`. These are output sampling times; FFmpeg selects a nearby source frame.

| Video time | Visible behavior |
| --- | --- |
| 4–6 s | Compact notch shows `Paused`, `Set center`, and `Enable`; the user selects `Set center`. |
| 6–7 s | First check opens: `Finding your center`, then `Looking for your face`, then the live preview. |
| 7–17 s | Alternates between green `Hold your head still` and red `Face the display`. The user is generally near the front-facing position. Progress repeatedly appears at roughly one third, then vanishes. Subtitles alternate among measuring camera and AirPods together, measuring screen direction, and waiting for steady AirPods motion. |
| 17.5–25.5 s | Prompts alternate between `Make one gentle head turn` and `Turn, then hold briefly`. Small visible head movements occur. Progress reaches roughly two thirds at 18.5 s and approximately 90% at 24.5 s, then disappears by 25 s. |
| 26–28 s | First failure. Live preview is replaced by the camera placeholder. `Try again` is available. |
| 28.5–35 s | Second check starts. The initial hold stage again alternates measuring and waiting; progress reaches roughly two thirds by 35 s. |
| 35.5–43 s | User visibly turns left, then right. The turn prompts, waiting-for-motion subtitle, `Face the display`, and `Looking for your face` replace one another. From 36.5 s onward, progress remains empty through the rest of this attempt. |
| 43.5–48.5 s | Alternating turn/waiting instructions continue as the user returns toward center and moves again. |
| 49–50.5 s | Second failure, same generic retry guidance. |
| 51–54 s | Third check starts. The user moves closer, making the face larger and brighter in the preview. Initial hold stage completes quickly enough to enter the turn stage. |
| 55–70.5 s | Repeated progress accumulation and resets. Approximate 90%-to-zero transitions occur at 57→57.5, 59.5→60, 61.5→62, 63.5→64, and 69.5→70 seconds. Several resets happen with little visible change in head pose and coincide with `Waiting for steady AirPods motion`. |
| 71–73.735 s | Third failure. Recording ends on the retry panel. |

## Rail behavior: partly responsive, with misleading recentering

The bottom curved ticks are **not completely frozen**. Their highlighted region and dot move during the pronounced turns in the second attempt. Measured on 0.5-second crops, the neutral dot is near absolute screen x = 1470; a left turn reaches approximately x = 1402 at 39 s, and a right turn reaches approximately x = 1527 at 42.5 s. State-dependent colors also change.

However, the feedback is inconsistent with the still-visible face pose:

- At 37.5 s the face is visibly turned left and the dot is left of center, around x = 1427.
- At 38 s the face remains visibly turned left, but the dot has returned close to center, around x = 1464. The subtitle has switched to `Waiting for steady AirPods motion`.
- Many other waiting samples place the marker at exactly its neutral position. This can look like rotation is being ignored or has been accepted as centered.

The recording shows a correlation between the waiting state and recentering. It does not establish which sensor or code path supplies those values.

## Implementation implications to verify in code

These are hypotheses and acceptance criteria, not findings from live sensor logs:

1. Inspect synchronization/freshness and stability gating between camera frames and headphone-motion samples. Progress should not be repeatedly destroyed by a single delayed sample or small transient after reaching about 90%.
2. Preserve valid partial calibration progress across brief interruptions when safe, with bounded expiry and clear restart conditions.
3. Keep directional visual feedback independent from the stricter eligibility rules for collecting calibration samples. An unavailable/ineligible sample should not masquerade as a centered pose.
4. Ensure the turn phase accepts the motion it asks for. Larger visible turns currently provoke face/front-facing rejection, while smaller turns frequently fail the turn/steady-motion gate.
5. Report a specific failure cause when the last obstacle is headphone motion availability or stability. The generic “keep your face visible and hold still” retry message does not explain the repeated waiting subtitle.

## Local evidence and privacy

Twenty-one tight notch crops, sampled OCR, and `rail-progress.tsv` are saved under ignored `build/notch-failure/`. The sampled evidence pairs are `evidence-01.png` / `evidence-02.png` (approximately 37.5→38 s, rail recentering with the head still turned) and `evidence-03.png` / `evidence-04.png` (approximately 57→57.5 s, progress resetting). Other `notch-*.png` files are direct seeks to their named time and can differ from the nearby sampled frame during rapid state changes. These contain the user's face and must not be committed, uploaded, or embedded in public reports. The exploratory full-desktop frame and unused frame batch were removed. This text report contains no face imagery or private chat text.
