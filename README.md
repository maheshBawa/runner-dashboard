# Runner Dashboard

A macOS menu bar app for watching and managing the self-hosted GitHub Actions runners on this Mac.

## Install

Requires macOS 14 or later on Apple silicon. Run this in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/maheshBawa/runner-dashboard/main/scripts/install.sh | bash
```

It installs the latest release into `~/Applications` and opens it in the menu bar. The app then updates itself.

## Release

[![Release](https://github.com/maheshBawa/runner-dashboard/actions/workflows/release.yml/badge.svg)](https://github.com/maheshBawa/runner-dashboard/actions/workflows/release.yml)

**[Release a new version →](https://github.com/maheshBawa/runner-dashboard/actions/workflows/release.yml)**

1. Open the link above and click **Run workflow**.
2. Choose `patch`, `minor` or `major`, and click **Run workflow** again.

CI bumps the latest tag (v1.2.3 → v1.2.4 / v1.3.0 / v2.0.0), tags `main`, builds and signs the app, and publishes the release. Installed copies offer the update within an hour.
