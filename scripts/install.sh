#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$TASK_ROOT/scripts/build.sh"
TASK_APP="$TASK_ROOT/build/AirVeil.app"
TASK_DEST="/Applications/AirVeil.app"
if [ -d "$TASK_DEST" ]; then
  TASK_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_DEST/Contents/Info.plist")
  if [ "$TASK_ID" != 'com.shivhax.airveil' ]; then echo 'A different application already occupies /Applications/AirVeil.app'; exit 1; fi
  pkill -x AirVeil || true
  for TASK_ATTEMPT in {1..20}; do
    if ! pgrep -x AirVeil >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x AirVeil >/dev/null; then echo "AirVeil is still closing; try again shortly."; exit 1; fi
  mv "$TASK_DEST" "$TASK_ROOT/build/AirVeil.previous.$(date +%s).app"
fi
ditto "$TASK_APP" "$TASK_DEST"
codesign --verify --strict "$TASK_DEST"
open "$TASK_DEST"
echo "Installed and opened $TASK_DEST"
