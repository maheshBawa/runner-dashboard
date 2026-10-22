#!/bin/bash
# Installs the latest release into ~/Applications and opens it:
#   curl -fsSL https://raw.githubusercontent.com/maheshBawa/runner-dashboard/main/scripts/install.sh | bash
# curl doesn't quarantine what it downloads, so the ad-hoc signed app opens without a Gatekeeper prompt.
set -euo pipefail
REPO=maheshBawa/runner-dashboard
APP="$HOME/Applications/Runner Dashboard.app"
[ "$(uname -m)" = arm64 ] || { echo "Runner Dashboard needs an Apple silicon Mac." >&2; exit 1; }
# releases/latest redirects to releases/tag/<tag>.
TAG=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Runner Dashboard $TAG…"
curl -fL --progress-bar -o "$TMP/app.zip" "https://github.com/$REPO/releases/download/$TAG/Runner-Dashboard-$TAG.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
pkill -x RunnerDash || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$TMP/Runner Dashboard.app" "$APP"
open "$APP"
echo "Installed $APP. It's in the menu bar."
