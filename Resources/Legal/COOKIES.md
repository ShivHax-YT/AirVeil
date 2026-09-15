# AirVeil Cookies and Local Storage

Effective date: September 14, 2026

AirVeil is developed by **ShivHax-YT**, an individual developer in Nevada, United States. Contact: [shivhax@gmail.com](mailto:shivhax@gmail.com). This notice explains storage used by the installed macOS app. Read the **Privacy Policy** in AirVeil's footer for the broader data practices.

## Browser cookies

The installed AirVeil app does not use browser cookies, browser local storage, tracking pixels, advertising identifiers, or an embedded browser. It does not run advertising or audience analytics. There is no advertising or analytics cookie choice to make inside this version of the app.

This does not mean that AirVeil saves nothing on your Mac. It uses native macOS preferences and, if explicitly enabled, a local diagnostic file. A browser's **Clear cookies** command does not remove those app files.

## What is stored locally

**Effect and feature preferences** remember blur thresholds, appearance, response, input blocking, camera enablement, removal behavior, seated brightness, selected displays, and energy mode. They persist until changed or removed. Reset defaults resets effect/feature choices and selected displays; it does not erase every app record.

**Camera setup** remembers the camera identifier, display-layout/configuration information, calibration values, and revision used for direction checks. It persists across launches and is replaced by a new center setup. Disabling the camera or resetting effect defaults does not remove this record. It contains no image or face-recognition identity template.

**The brightness recovery record** restores the previous brightness after an interrupted operation. It exists while recovery is pending and is cleared after recovery or when AirVeil no longer owns that brightness setting. Restore brightness before manually deleting app preferences.

**Tutorial completion and permission-setup progress** avoid repeating completed steps and allow interrupted setup to resume. Permission records include the setup stage, explanations reviewed, and choices to continue with or without access. They persist across launches and updates. Reset defaults does not erase them. They do not override macOS permission decisions.

**Explicit diagnostic output** helps inspect operational behavior when the app is launched with a diagnostic-file option. The specified file is overwritten with current status while diagnostics runs and remains until you remove it. It is not automatically uploaded.

Current camera frames, preview images, desktop frames, motion-processing buffers, and the foreground-seat geometry are processed in memory. The seat geometry is not a persistent preference. These are not browser cookies, and the app does not save image, video, or audio recordings.

AirVeil's preferences belong to the macOS preference domain `com.shivhax.airveil`. macOS manages their physical storage. The current app has no single **Erase all local data** command and no preference that makes every setting session-only. Uninstalling the app can leave preferences or diagnostic files behind. Operating-system permission choices are separate from AirVeil's preferences.

## Your choices

Change feature settings in AirVeil, revoke available device permissions in **System Settings → Privacy & Security**, and remove diagnostic files you created when no longer needed. Quit the app to stop its running processing. Closing Settings alone leaves enabled background features running.

The **Privacy Policy** in AirVeil's footer explains optional camera operation, what Reset defaults retains, brightness recovery, and local-data controls. Deleting browser cookies does not disable AirVeil's device permissions or remove native preferences.

## Websites you visit separately

GitHub's download and repository pages are websites outside the installed app. Your browser and GitHub manage their cookies and website storage under [GitHub's cookie policy](https://docs.github.com/en/site-policy/privacy-policies/github-cookies). Review those choices on the website. This notice does not claim that external websites are cookie-free.

## Why this notice does not show a generic cookie banner

The current app has no browser-cookie, advertising, or analytics system to accept or reject. This notice describes its actual storage rather than presenting choices for features it does not have.

Native storage can be subject to privacy requirements even without browser cookies. The storage described here supports the stated app features; this notice does not ask you to approve advertising, analytics, or unrelated data use. Any future web view, analytics, remote service, or additional storage purpose requires updated information and any choices required by applicable law before use.
