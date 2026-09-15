#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_ROOT/Resources/Info.plist")"
TASK_ARCH="$(uname -m)"
if [[ "$TASK_ARCH" != arm64 ]]; then
  echo 'This release package targets Apple silicon. Build on an Apple silicon Mac.' >&2
  exit 1
fi
TASK_OUTPUT="$TASK_ROOT/build/releases"
TASK_NAME="AirVeil-$TASK_VERSION-apple-silicon.dmg"
mkdir -p "$TASK_OUTPUT"
if [[ -e "$TASK_OUTPUT/$TASK_NAME" ]]; then
  echo "Release artifact already exists: $TASK_OUTPUT/$TASK_NAME" >&2
  exit 1
fi
bash "$TASK_ROOT/scripts/build.sh"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
ditto "$TASK_ROOT/build/AirVeil.app" "$TASK_STAGE/AirVeil.app"
codesign --verify --strict "$TASK_STAGE/AirVeil.app"
ln -s /Applications "$TASK_STAGE/Applications"
cat > "$TASK_STAGE/Install AirVeil.txt" <<'EOF'
AirVeil for Apple silicon — prerelease

1. Quit an older AirVeil version normally before replacing it.
2. Drag AirVeil.app onto the Applications shortcut.
3. Open AirVeil from Applications, then eject this disk image.
4. Review the permission cards, then follow the interactive Settings tour.
   Permissions and the tour can be revisited from Settings.

Requires macOS 14 or later and compatible head-tracking AirPods.
This is a development-signed build, not Apple-notarized. macOS may
block its first launch on another Mac. No security settings are changed
by this disk image.

Motion permission enables head tracking. Camera assistance is optional
and uses a separate permission. Screen Recording permission is only
needed for live desktop blur; removal, brightness and display-off
features work without it. Images and screen frames stay on the Mac.

Automatic display management uses a sustained loss of headphone motion
for the both-AirPods workflow. A connection interruption can produce
the same signal; individual earbuds are not identified. With camera
assistance and seated dimming enabled, a seat check can dim the built-in
display while you remain seated and request display sleep after confirmed
absence. An uncertain or unavailable check does not request sleep.
Returning motion restores owned brightness, even if only one bud is in.
If the Mac is locked or asleep, restoration waits until the session and
display are active. Verify both unlock/reinsert orders on your hardware.

Settings are organized into Preview, Tracking, Displays, Appearance,
and Power. Sync head in Appearance runs a camera alignment, then lets
the head illustration follow live AirPods turns without changing your
blur thresholds. Enable blur while AirPods are out waits for motion,
checks alignment with the camera, then starts blur after valid tracking.

The wear-AirPods reminder includes Turn off feature. It restores owned
brightness and pauses blur and automatic camera/removal checks until
you explicitly enable a feature again. This choice persists at relaunch.

If automatic display management remains on while camera assistance or
seated dimming is off, sustained motion loss requests display sleep
directly, without a camera check. Disable automatic display management
separately if you do not want this. Password-on-wake follows your macOS
Lock Screen settings. Keep Automatic Ear Detection on and verify the
behavior on your own hardware before relying on this prerelease.

Terms of Use, Privacy Policy, and Cookies & Local Storage are available
offline from the footer in AirVeil. There are no advertising or analytics
SDKs and no browser cookies in the app. Developer animation-preview
commands are excluded from this release build.

Source and release notes: https://github.com/ShivHax-YT/AirVeil
EOF
hdiutil create -volname "AirVeil $TASK_VERSION" -srcfolder "$TASK_STAGE" \
  -format UDZO -imagekey zlib-level=9 "$TASK_OUTPUT/$TASK_NAME"
hdiutil verify "$TASK_OUTPUT/$TASK_NAME"
(cd "$TASK_OUTPUT" && shasum -a 256 "$TASK_NAME" > "$TASK_NAME.sha256")
echo "Created $TASK_OUTPUT/$TASK_NAME"
