#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
TASK_SOURCES=()
for TASK_SOURCE in "$TASK_ROOT"/Sources/*.swift; do
  case "$TASK_SOURCE" in */main.swift|*/AppDelegate.swift) continue ;; esac
  TASK_SOURCES+=("$TASK_SOURCE")
done
mkdir -p "$TASK_ROOT/build/tests"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  "${TASK_SOURCES[@]}" "$TASK_ROOT/Tests/VeilPreviewTests.swift" -o "$TASK_ROOT/build/tests/veil-preview-tests"
"$TASK_ROOT/build/tests/veil-preview-tests" "$TASK_ROOT/build/preview-tests"
