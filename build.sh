#!/bin/bash
# Builds ~/Applications/Runner Dashboard.app (or $APP, versioned $VERSION, else the latest git tag) from RunnerDash.swift + Features.swift and runs its self-check.
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP:-$HOME/Applications/Runner Dashboard.app}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# App icon: drawn by icon.swift, regenerated only when icon.swift changes.
if [ ! -f AppIcon.icns ] || [ icon.swift -nt AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 icon.swift -o "$TMP/icon"
  "$TMP/icon" "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
  rm -rf "$TMP"
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 RunnerDash.swift Features.swift -o "$APP/Contents/MacOS/RunnerDash"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>RunnerDash</string>
  <key>CFBundleIdentifier</key><string>local.runner-dashboard</string>
  <key>CFBundleName</key><string>Runner Dashboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>APP_VERSION</string>
  <key>CFBundleVersion</key><string>BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>Runner Dashboard reads the name of the Wi-Fi network you're on so it can track data usage per network. Your location is never used or stored.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Runner Dashboard reads the name of the Wi-Fi network you're on so it can track data usage per network. Your location is never used or stored.</string>
</dict></plist>
EOF
# A new build number per build makes Finder and Notification Center reload the icon instead of using a cached copy.
sed -i '' -e "s/BUILD_NUMBER/$(date +%Y%m%d%H%M%S)/" -e "s/APP_VERSION/${VERSION#v}/" "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
# Tell Finder, Spotlight and Notification Center about the (new) icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
"$APP/Contents/MacOS/RunnerDash" --selftest
echo "Built: $APP"
