#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
TASK_ARCH="$(uname -m)"
TASK_SWIFT_FLAGS=(-D AIRVEIL_RELEASE)
TASK_CONFIGURATION=release
if [[ "${1:-}" == --development ]]; then
  TASK_CONFIGURATION=development
  TASK_SWIFT_FLAGS=(-D AIRVEIL_DEVELOPMENT)
elif [[ $# -gt 0 ]]; then
  echo 'Usage: scripts/build.sh [--development]' >&2
  exit 1
fi
TASK_SIGNING="$HOME/Library/Application Support/AirVeil/Signing"
if [ ! -f "$TASK_SIGNING/identity-sha1" ]; then
  echo 'Set up a persistent identity first: python3 scripts/setup-signing.py'
  exit 1
fi
TASK_IDENTITY="$(cat "$TASK_SIGNING/identity-sha1")"
if [[ ! "$TASK_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]; then echo 'Invalid signing identity fingerprint'; exit 1; fi
TASK_APP="$TASK_ROOT/build/AirVeil.app"
if [[ "$TASK_CONFIGURATION" == development ]]; then
  TASK_APP="$TASK_ROOT/build/development/AirVeil.app"
fi
for TASK_POLICY in TERMS PRIVACY COOKIES; do
  if [[ ! -s "$TASK_ROOT/Resources/Legal/$TASK_POLICY.md" ]]; then
    echo "Missing required policy: Resources/Legal/$TASK_POLICY.md" >&2
    exit 1
  fi
done
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macos14.0" -swift-version 5 -O \
  -module-cache-path "$TASK_ROOT/.build/module-cache" \
  "${TASK_SWIFT_FLAGS[@]}" \
  "$TASK_ROOT"/Sources/*.swift -o "$TASK_APP/Contents/MacOS/AirVeil" \
  -framework AppKit -framework SwiftUI -framework Combine -framework CoreMotion \
  -framework ScreenCaptureKit -framework Metal -framework MetalKit \
  -framework MetalPerformanceShaders -framework CoreVideo -framework QuartzCore -framework Carbon \
  -framework AVFoundation -framework Vision -framework CoreMedia -framework ImageIO -framework IOKit
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "$TASK_ROOT/Resources/Veil.metal" "$TASK_APP/Contents/Resources/Veil.metal"
ditto "$TASK_ROOT/Resources/Legal" "$TASK_APP/Contents/Resources/Legal"
TASK_ICONSET="$TASK_ROOT/build/AirVeil.iconset"
mkdir -p "$TASK_ICONSET"
xcrun swift -sdk "$TASK_SDK" "$TASK_ROOT/scripts/make-icon.swift" "$TASK_ROOT/build/AppIcon.png"
for TASK_SIZE in 16 32 128 256 512; do
  sips -z "$TASK_SIZE" "$TASK_SIZE" "$TASK_ROOT/build/AppIcon.png" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
  TASK_DOUBLE=$((TASK_SIZE * 2))
  sips -z "$TASK_DOUBLE" "$TASK_DOUBLE" "$TASK_ROOT/build/AppIcon.png" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_ICONSET" -o "$TASK_APP/Contents/Resources/AppIcon.icns"
swift -suppress-warnings -sdk "$TASK_SDK" "$TASK_ROOT/scripts/signing-keychain.swift" sign "$TASK_SIGNING" "$TASK_APP"
codesign --verify --strict "$TASK_APP"
echo "Built $TASK_APP"
