# Runner Dashboard

Native SwiftUI menu bar + window app (macOS 14+, Apple silicon) for the self-hosted GitHub Actions runners on this Mac:
`~/actions-runner*`, each running as a user LaunchAgent. It's a SwiftPM package with no Xcode project, built by `scripts/build.sh`.

## Layout

```
Package.swift                  two executable targets, Swift 5 language mode, Sparkle 2 dependency
Sources/RunnerDash/            the app
  App/                         entry point, scenes, --selftest
  Core/                        runner discovery, Store, network accounting, automation, Sparkle updater (no views)
  Views/                       SwiftUI screens and building blocks
Sources/IconTool/              draws the app icon PNG
Resources/Info.plist           template: build.sh fills APP_VERSION and BUILD_NUMBER
scripts/build.sh               build, bundle (embeds Sparkle.framework), ad-hoc sign, install to ~/Applications, run --selftest
scripts/install.sh             the README's curl | bash installer: latest release zip -> ~/Applications, no quarantine
docs/                          README screenshots (runner, Wi-Fi and Mac names replaced with placeholders)
.github/workflows/release.yml  Run workflow (bump) or v* tag -> build on the self-hosted runner -> GitHub release with the zip + signed appcast.xml
```

## Commands

- Build and install: `scripts/build.sh`. Use `APP=<path>` to build elsewhere and `VERSION=x.y.z` to override the version, which defaults to the latest git tag.
- Self-check: `~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest`, which prints `ok`. It's assert-based. Add a `precondition` there for new non-trivial logic.
- Other flags: `--notify-test` posts a sample notification, and `--preview-icon` makes the running app play its busy menu bar animation.
- Edit in Xcode: `xed .` opens the package.

## Workflow

- Deliver every feature and fix as a PR. Branch from `main` (`feat/…`, `fix/…`, `chore/…`), push, then `gh pr create`. Never commit or push to `main` directly: the user reviews and merges.
- Before opening a PR, `scripts/build.sh` must pass (it runs `--selftest`). For UI changes, also check them in the running app.
- Releases: the user runs Actions › Release › Run workflow and picks patch, minor or major (linked from README.md). CI bumps the latest tag, tags `main` and publishes. Pushing a `vX.Y.Z` tag still works for a specific version. Installed copies offer the update within an hour.
- Release runner: `Runner-Dashboard-builder`, registered to this repo only, in `~/actions-runner-runner-dashboard` on the user's Mac. It uses that Mac's Xcode and the `gh` on its PATH. macOS registers any app bundle it sees, so the Clean up step unregisters the build (`lsregister -u`) and deletes it. Otherwise a second copy with the same bundle id stays on the Mac.
- The repo is public and that runner is the user's Mac. Any workflow run on it has full access as the user: other runners' credentials, keys, persistence. Fork PRs bring their own workflow files, so the repo requires approval for every outside contributor's run (Settings › Actions › General › Fork pull request workflows). Never suggest approving a run without reading the PR's `.github/` changes, and keep `release.yml` limited to tag push and `workflow_dispatch`, which outsiders can't trigger.

## App updates (Sparkle)

- Installed apps read `SUFeedURL`, which is `releases/latest/download/appcast.xml`. That only works while the repo is public.
- Sparkle compares `CFBundleVersion`, which `build.sh` sets to `<version>.<UTC build time>`, so the version decides. A pure timestamp broke this once: a local build in IST outranked a newer CI release built in UTC. `--selftest` checks the format.
- A scheduled find shows the "Update available" banner instead of a window (gentle reminders, `Core/AppUpdater.swift`). "Update now" and Settings › Check for Updates… open Sparkle's own window, which handles download, install and relaunch.
- Signing key: the private EdDSA key is in the login Keychain (`generate_keys`), and CI has a copy in the `SPARKLE_PRIVATE_KEY` secret. Its public half is `SUPublicEDKey` in `Resources/Info.plist`. Losing or changing the key strands every installed copy, because without a Developer ID there's no way to rotate it. Keep a backup: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`.
- To test locally:
  1. Install an older build with `VERSION=1.1.9 scripts/build.sh`.
  2. Then build a newer one with `APP=dist/new/...`, and zip it into `dist/feed`.
  3. Run `generate_appcast --download-url-prefix http://127.0.0.1:8765/ dist/feed`, then serve it with `python3 -m http.server 8765 --directory dist/feed`.
  4. Run `defaults write local.runner-dashboard SUFeedURL http://127.0.0.1:8765/appcast.xml` and set `SULastCheckTime` to an old date.
  5. Relaunch the older build.
  6. Afterwards, run `defaults delete local.runner-dashboard SUFeedURL`.

## Don't break

- Keep the bundle name `Runner Dashboard.app`, the executable `Contents/MacOS/RunnerDash`, the bundle id `local.runner-dashboard` and exactly one `*.zip` per release. The pre-Sparkle `gh` updater in v1.1.0 depends on all four, as well as on `--selftest` passing on a clean machine. `scripts/install.sh` also expects the zip to be named `Runner-Dashboard-<tag>.zip`.
- Swift 5 language mode: the existing code doesn't build under Swift 6 strict concurrency.
- File-scoped state must stay in the same file as its users. That covers the top-level `private` caches (`runLinkCache`, `serviceLogCache`) and `Automation`'s `private(set)` properties, which the app-update extension sets.
- `UNUserNotificationCenter` crashes outside an app bundle, so guard on `Bundle.main.bundleIdentifier`.
- App icon: custom shapes only. SF Symbols aren't allowed in app icons.
- Stop always asks for confirmation: accidental clicks stopped runners before.

## Runner and system gotchas

- The listener spawns jobs from the versioned dir (`<runner>/bin.2.x.y/Runner.Worker`), not `<runner>/bin/`, so busy detection must match both.
- `gh` has no `admin:org` scope, so GitHub-side runner status isn't available. Everything comes from local files and processes.
- Add Runner (`Core/RunnerSetup.swift`) has these requirements:
  - It runs `config.sh` through the user's interactive login shell. `config.sh` saves its PATH and tool variables to `.path`/`.env` for every job, and the app's own environment has no Homebrew.
  - `svc.sh` must run from the runner folder, because it uses `pwd`.
  - The registration token comes from the pasted command, since the app has no GitHub login.
- `nettop -P -L 0` (per-runner network usage) has these quirks:
  - Run it on a pty: into a pipe it buffers output for minutes.
  - Its stdin must never hit EOF, or it spins at ~145% CPU.
  - `readabilityHandler` never fires on a pty master, so read it on a blocking thread.
  - Snapshot parent pids at 4 Hz, because short downloads finish between nettop samples.
- Data lives in `~/Library/Application Support/Runner Dashboard/`, for example `network-usage.json`, keyed by local hour start.

## Checking the UI from a terminal

- The terminal has Accessibility permission but not Screen Recording, so read the UI through System Events (`entire contents of window 1` of process "RunnerDash").
- An AX click doesn't open the MenuBarExtra panel. Post a CGEvent mouse click on the status item instead; System Events gives its position (`menu bar item 1 of menu bar 2`).
- Sparkle's windows are plain AppKit, so System Events can read their buttons ("Install Update", "Install and Relaunch").
- `log` is a zsh builtin: use `/usr/bin/log show`.
