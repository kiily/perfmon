#!/bin/bash
# build.sh — compile Perfmon.app: arm64, size-optimised, stripped, signed, packed in a DMG.
# Usage: app/build.sh [--install]    SIGN_ID="Developer ID Application: …" to sign for distribution.
# Output: app/build/Perfmon.app and app/build/Perfmon.dmg (drag-to-Applications installer).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/build"
APP="$OUT/Perfmon.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/icon"
cp "$DIR/Info.plist" "$APP/Contents/"
# ponytail: arm64 only; add `-target x86_64-apple-macos14.0` + lipo if an Intel Mac ever needs it.
swiftc -Osize -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Perfmon" "$DIR"/*.swift
strip -x "$APP/Contents/MacOS/Perfmon"

# Icon Composer source → .icns. actool's .icns already renders as a proper
# macOS 26+ icon; its Assets.car (live glass/tint variants) costs 1.8 MB, so skip it.
xcrun actool "$DIR/AppIcon.icon" --compile "$OUT/icon" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$OUT/icon/partial.plist" >/dev/null
cp "$OUT/icon/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$OUT/icon"

codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# HFS+: half the size of an APFS image for one small app.
hdiutil create -quiet -volname Perfmon -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$OUT/Perfmon.dmg"
rm -rf "$STAGE"
echo "built $APP ($(du -sh "$APP" | cut -f1), dmg $(du -h "$OUT/Perfmon.dmg" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  pkill -x Perfmon 2>/dev/null || true
  while pgrep -x Perfmon >/dev/null; do sleep 0.2; done   # open fails (-600) while the old one is still quitting
  rm -rf /Applications/Perfmon.app
  cp -R "$APP" /Applications/
  open /Applications/Perfmon.app
  echo "installed /Applications/Perfmon.app"
fi
