#!/bin/bash
# Builds ~/Applications/Runner Dashboard.app (or $APP, versioned $VERSION, else the latest git tag) and runs its self-check.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP:-$HOME/Applications/Runner Dashboard.app}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0)}"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# App icon: drawn by IconTool, regenerated only when its source changes.
ICNS=.build/AppIcon.icns
if [ ! -f $ICNS ] || [ Sources/IconTool/IconTool.swift -nt $ICNS ]; then
  TMP=$(mktemp -d)
  "$BIN/IconTool" "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o $ICNS
  rm -rf "$TMP"
fi
cp $ICNS "$APP/Contents/Resources/AppIcon.icns"
# A fresh file rather than overwriting in place, so a running copy of the app doesn't crash on a changed binary.
rm -f "$APP/Contents/MacOS/RunnerDash"
cp "$BIN/RunnerDash" "$APP/Contents/MacOS/RunnerDash"
# A new build number per build makes Finder and Notification Center reload the icon instead of using a cached copy.
sed -e "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" -e "s/APP_VERSION/${VERSION#v}/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
# Tell Finder, Spotlight and Notification Center about the (new) icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
"$APP/Contents/MacOS/RunnerDash" --selftest
echo "Built: $APP"
