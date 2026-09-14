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

Requires macOS 14 or later and compatible head-tracking AirPods.
This is a development-signed build, not Apple-notarized. macOS may
block its first launch on another Mac. No security settings are changed
by this disk image.

Motion permission enables head tracking. Camera assistance is optional
and uses a separate permission. Screen Recording permission is only
needed for live desktop blur; removal, brightness and display-off
features work without it. Images and screen frames stay on the Mac.

Hardware testing is pending, including removal of the non-tracking
AirPod and brightness restoration. Per-ear status depends on private
macOS compatibility interfaces. Treat this as a test build.

Source and release notes: https://github.com/ShivHax-YT/AirVeil
EOF
hdiutil create -volname "AirVeil $TASK_VERSION" -srcfolder "$TASK_STAGE" \
  -format UDZO -imagekey zlib-level=9 "$TASK_OUTPUT/$TASK_NAME"
hdiutil verify "$TASK_OUTPUT/$TASK_NAME"
(cd "$TASK_OUTPUT" && shasum -a 256 "$TASK_NAME" > "$TASK_NAME.sha256")
echo "Created $TASK_OUTPUT/$TASK_NAME"
