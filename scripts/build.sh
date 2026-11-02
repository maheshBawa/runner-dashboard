#!/bin/bash
# Builds ~/Applications/Runner Dashboard.app (or $APP, versioned $VERSION, else the latest git tag) and runs its self-check.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP:-$HOME/Applications/Runner Dashboard.app}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0)}"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# App icon: the Icon Composer document, compiled only when it changes (needs Xcode 26). macOS 26+ draws its layers from
# Assets.car; earlier versions use AppIcon.icns.
ICON=.build/icon
if [ ! -f $ICON/Assets.car ] || [ -n "$(find Resources/AppIcon.icon -newer $ICON/Assets.car)" ]; then
  mkdir -p $ICON
  xcrun actool Resources/AppIcon.icon --compile $ICON --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist $ICON/partial.plist >/dev/null
fi
cp $ICON/Assets.car $ICON/AppIcon.icns "$APP/Contents/Resources/"
# A fresh file rather than overwriting in place, so a running copy of the app doesn't crash on a changed binary.
rm -f "$APP/Contents/MacOS/RunnerDash"
cp "$BIN/RunnerDash" "$APP/Contents/MacOS/RunnerDash"
# Sparkle (app updates) loads from Contents/Frameworks; ditto keeps the framework's symlinks.
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Build number "<version>.<UTC build time>": Sparkle compares it, so the version decides and the time only breaks ties
# (UTC, so CI and local builds agree). Changing per build also makes Finder and Notification Center reload the icon.
sed -e "s/BUILD_NUMBER/${VERSION#v}.$(date -u +%Y%m%d%H%M%S)/" -e "s/APP_VERSION/${VERSION#v}/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
# Tell Finder, Spotlight and Notification Center about the (new) icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
"$APP/Contents/MacOS/RunnerDash" --selftest
echo "Built: $APP"
