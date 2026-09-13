#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
TASK_ARCH="$(uname -m)"
TASK_APP="$TASK_ROOT/build/AirVeil.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
swiftc -sdk "$TASK_SDK" -target "$TASK_ARCH-apple-macos14.0" -swift-version 5 -O \
  "$TASK_ROOT"/Sources/*.swift -o "$TASK_APP/Contents/MacOS/AirVeil" \
  -framework AppKit -framework SwiftUI -framework Combine -framework CoreMotion \
  -framework ScreenCaptureKit -framework Metal -framework MetalKit \
  -framework MetalPerformanceShaders -framework CoreVideo -framework QuartzCore -framework Carbon
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "$TASK_ROOT/Resources/Veil.metal" "$TASK_APP/Contents/Resources/Veil.metal"
codesign --force --sign - "$TASK_APP"
codesign --verify --strict "$TASK_APP"
echo "Built $TASK_APP"
