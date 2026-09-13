#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$TASK_ROOT/build/tests"
swiftc -sdk "$TASK_SDK" "$TASK_ROOT/Sources/NotchGeometry.swift" \
  "$TASK_ROOT/Tests/NotchGeometryTests.swift" -o "$TASK_ROOT/build/tests/notch-geometry"
"$TASK_ROOT/build/tests/notch-geometry"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/CameraAnchorService.swift" "$TASK_ROOT/Sources/NotchCoachState.swift" \
  "$TASK_ROOT/Sources/NotchCoachView.swift" "$TASK_ROOT/Sources/NotchGeometry.swift" \
  "$TASK_ROOT/Sources/NotchOverlayController.swift" "$TASK_ROOT/Tests/NotchOverlayLifecycleTests.swift" \
  -o "$TASK_ROOT/build/tests/notch-lifecycle"
"$TASK_ROOT/build/tests/notch-lifecycle"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/CameraAnchorService.swift" "$TASK_ROOT/Sources/NotchCoachState.swift" \
  "$TASK_ROOT/Sources/NotchCoachView.swift" "$TASK_ROOT/Tests/NotchViewRender.swift" \
  -o "$TASK_ROOT/build/tests/notch-render"
"$TASK_ROOT/build/tests/notch-render" "$TASK_ROOT/build/notch-previews"
