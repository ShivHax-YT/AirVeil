#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
mkdir -p "$TASK_ROOT/build/tests"
swiftc -sdk "$TASK_SDK" "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Tests/MotionMathTests.swift" -o "$TASK_ROOT/build/tests/motion-math"
"$TASK_ROOT/build/tests/motion-math"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "$TASK_ROOT/Sources/VeilMetalView.swift" "$TASK_ROOT/Tests/RenderTests.swift" \
  -o "$TASK_ROOT/build/tests/render-tests"
"$TASK_ROOT/build/tests/render-tests" "$TASK_ROOT"
