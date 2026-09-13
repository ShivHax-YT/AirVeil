#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
mkdir -p "$TASK_ROOT/build/tests"
swiftc -sdk "$TASK_SDK" "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Tests/MotionMathTests.swift" -o "$TASK_ROOT/build/tests/motion-math"
"$TASK_ROOT/build/tests/motion-math"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 6 \
  "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Sources/MotionService.swift" \
  "$TASK_ROOT/Tests/MotionDeliveryTests.swift" -o "$TASK_ROOT/build/tests/motion-delivery"
"$TASK_ROOT/build/tests/motion-delivery"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 6 \
  "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Sources/MotionService.swift" \
  "$TASK_ROOT/Tests/MotionReferenceLifecycleTests.swift" -o "$TASK_ROOT/build/tests/motion-reference"
"$TASK_ROOT/build/tests/motion-reference"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/AppModel.swift" "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Sources/AirPodsRemovalGuard.swift" \
  "$TASK_ROOT/Tests/AppModelLifecycleTests.swift" -o "$TASK_ROOT/build/tests/appmodel-lifecycle"
"$TASK_ROOT/build/tests/appmodel-lifecycle"
swiftc -sdk "$TASK_SDK" "$TASK_ROOT/Sources/AirPodsRemovalGuard.swift" \
  "$TASK_ROOT/Tests/AirPodsRemovalGuardTests.swift" -o "$TASK_ROOT/build/tests/removal-policy"
"$TASK_ROOT/build/tests/removal-policy"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/DisplaySleepService.swift" "$TASK_ROOT/Tests/DisplaySleepServiceTests.swift" \
  -o "$TASK_ROOT/build/tests/display-sleep"
"$TASK_ROOT/build/tests/display-sleep"
swiftc -sdk "$TASK_SDK" "$TASK_ROOT/Sources/VeilInputGeometry.swift" \
  "$TASK_ROOT/Tests/InputGeometryTests.swift" -o "$TASK_ROOT/build/tests/input-geometry"
"$TASK_ROOT/build/tests/input-geometry"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/VeilMetalView.swift" "$TASK_ROOT/Sources/VeilInputGeometry.swift" "$TASK_ROOT/Tests/RenderTests.swift" \
  -o "$TASK_ROOT/build/tests/render-tests"
"$TASK_ROOT/build/tests/render-tests" "$TASK_ROOT"
if [ "${1:-}" = '--performance' ]; then
  swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 -O \
    "$TASK_ROOT/Sources/VeilMetalView.swift" "$TASK_ROOT/Tests/PerformanceTests.swift" \
    -o "$TASK_ROOT/build/tests/performance-tests"
  (cd "$TASK_ROOT" && "$TASK_ROOT/build/tests/performance-tests")
fi
