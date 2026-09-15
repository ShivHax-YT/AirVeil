#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
mkdir -p "$TASK_ROOT/build/tests" "$TASK_ROOT/.build/module-cache"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
 -module-cache-path "$TASK_ROOT/.build/module-cache" \
 "$TASK_ROOT/Sources/AppModel.swift" "$TASK_ROOT/Sources/TrackingPresentation.swift" \
 "$TASK_ROOT/Sources/HeadPreviewSyncPresentation.swift" \
 "$TASK_ROOT/Sources/PresenceTracker.swift" "$TASK_ROOT/Sources/RemovalPresenceCoordinator.swift" \
 "$TASK_ROOT/Sources/VeilMath.swift" "$TASK_ROOT/Sources/AirPodsRemovalGuard.swift" \
 "$TASK_ROOT/Tests/AppModelLifecycleTests.swift" -o "$TASK_ROOT/build/tests/appmodel-lifecycle"
"$TASK_ROOT/build/tests/appmodel-lifecycle"
