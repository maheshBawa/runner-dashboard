# Runner Dashboard

Native SwiftUI menu bar + window app (macOS 14+, Apple silicon) for the self-hosted GitHub Actions runners on this Mac:
`~/actions-runner*`, each running as a user LaunchAgent. It's a SwiftPM package with no Xcode project, built by `scripts/build.sh`.

## Layout

```
Package.swift                  two executable targets, Swift 5 language mode
Sources/RunnerDash/            the app
  App/                         entry point, scenes, --selftest
  Core/                        runner discovery, Store, network accounting, automation, app updates (no views)
  Views/                       SwiftUI screens and building blocks
Sources/IconTool/              draws the app icon PNG
Resources/Info.plist           template: build.sh fills APP_VERSION and BUILD_NUMBER
scripts/build.sh               build, bundle, ad-hoc sign, install to ~/Applications, run --selftest
.github/workflows/release.yml  v* tag -> build on macos-26 -> GitHub release with one zip
```

## Commands

- Build and install: `scripts/build.sh`. Use `APP=<path>` to build elsewhere and `VERSION=x.y.z` to override the version, which defaults to the latest git tag.
- Self-check: `~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest`, which prints `ok`. It's assert-based. Add a `precondition` there for new non-trivial logic.
- Other flags: `--notify-test` posts a sample notification, and `--preview-icon` makes the running app play its busy menu bar animation.
- Edit in Xcode: `xed .` opens the package.

## Workflow

- Deliver every feature and fix as a PR. Branch from `main` (`feat/…`, `fix/…`, `chore/…`), push, then `gh pr create`. Never commit or push to `main` directly: the user reviews and merges.
- Before opening a PR, `scripts/build.sh` must pass (it runs `--selftest`). For UI changes, also check them in the running app.
- Releases: after a merge, tag `main` with `vX.Y.Z` and push the tag. The workflow publishes the release, and installed copies offer the update within an hour.

## Don't break

- Keep the bundle name `Runner Dashboard.app`, the executable `Contents/MacOS/RunnerDash`, the bundle id `local.runner-dashboard` and a single `*.zip` release asset. The updater in copies already installed depends on all four.
- `--selftest` must pass on a clean machine with no runners and no network. The updater refuses a download whose self-check fails.
- Swift 5 language mode: the existing code doesn't build under Swift 6 strict concurrency.
- File-scoped state must stay in the same file as its users. That covers the top-level `private` caches (`runLinkCache`, `serviceLogCache`) and `Automation`'s `private(set)` properties, which the app-update extension sets.
- `UNUserNotificationCenter` crashes outside an app bundle, so guard on `Bundle.main.bundleIdentifier`.
- App icon: custom shapes only. SF Symbols aren't allowed in app icons.
- Stop always asks for confirmation: accidental clicks stopped runners before.

## Runner and system gotchas

- The listener spawns jobs from the versioned dir (`<runner>/bin.2.x.y/Runner.Worker`), not `<runner>/bin/`, so busy detection must match both.
- `gh` has no `admin:org` scope, so GitHub-side runner status isn't available. Everything comes from local files and processes.
- `nettop -P -L 0` (per-runner network usage) has these quirks:
  - Run it on a pty: into a pipe it buffers output for minutes.
  - Its stdin must never hit EOF, or it spins at ~145% CPU.
  - `readabilityHandler` never fires on a pty master, so read it on a blocking thread.
  - Snapshot parent pids at 4 Hz, because short downloads finish between nettop samples.
- Data lives in `~/Library/Application Support/Runner Dashboard/`, for example `network-usage.json`, keyed by local hour start.
- App updates (`Core/Automation.swift`) go through the user's `gh` login, because the repo is private.

## Checking the UI from a terminal

- The terminal has Accessibility permission but not Screen Recording, so read the UI through System Events (`entire contents of window 1` of process "RunnerDash").
- An AX click doesn't open the MenuBarExtra panel. Post a CGEvent mouse click on the status item instead; System Events gives its position (`menu bar item 1 of menu bar 2`).
- To test the updater, `VERSION=1.0.1 scripts/build.sh` installs a build labelled older than the latest release.
