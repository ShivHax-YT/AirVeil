#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/build/tests/LegalReader.app"
TASK_SDK="${AIRVEIL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$TASK_SDK" ]; then TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>LegalReader</string><key>CFBundleIdentifier</key><string>com.shivhax.airveil.legal-render</string></dict></plist>
PLIST
ditto "$TASK_ROOT/Resources/Legal" "$TASK_APP/Contents/Resources/Legal"
swiftc -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  -module-cache-path "$TASK_ROOT/.build/module-cache" \
  "$TASK_ROOT/Sources/LegalDocuments.swift" "$TASK_ROOT/Tests/LegalDocumentsRender.swift" \
  "$TASK_ROOT/Sources/InteractionHaptics.swift" \
  -o "$TASK_APP/Contents/MacOS/LegalReader"
"$TASK_APP/Contents/MacOS/LegalReader" "$TASK_ROOT/build/legal-previews"
