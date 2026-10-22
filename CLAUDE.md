# Runner Dashboard

Native SwiftUI menu bar + window app (macOS 14+, Apple silicon) for the self-hosted GitHub Actions runners on this Mac,
usually `~/actions-runner*`, each running as a user LaunchAgent. It's a SwiftPM package with no Xcode project, built by `scripts/build.sh`.

## Layout

```
Package.swift                  two executable targets, Swift 5 language mode, Sparkle 2 dependency
Sources/RunnerDash/            the app
  App/                         entry point, scenes, --selftest
  Core/                        runner discovery, Store, Add Runner setup, network accounting, automation, Sparkle updater (no views)
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
  - Without `APP`, it replaces the copy in `~/Applications`, which is the app the user runs every day.
  - The old process keeps running until it's relaunched: `pkill -x RunnerDash; open ~/Applications/Runner\ Dashboard.app`.
- Self-check: `~/Applications/Runner\ Dashboard.app/Contents/MacOS/RunnerDash --selftest`, which prints `ok`. It's assert-based. Add a `precondition` there for new non-trivial logic.
- Other flags: `--notify-test` posts a sample notification, and `--preview-icon` makes the running app play its busy menu bar animation.
- Edit in Xcode: `xed .` opens the package.

## Workflow

- Deliver every feature and fix as a PR. Branch from `main` (`feat/…`, `fix/…`, `chore/…`), push, then `gh pr create`. Never commit or push to `main` directly: the user reviews and merges.
- Before opening a PR, `scripts/build.sh` must pass (it runs `--selftest`). For UI changes, also check them in the running app. Say in the PR what you couldn't test, for example a path that needs a real GitHub token.
- Releases: the user runs Actions › Release › Run workflow and picks patch, minor or major (linked from README.md). CI bumps the latest tag, tags `main` and publishes. Pushing a `vX.Y.Z` tag still works for a specific version. Installed copies offer the update within an hour.
- Screenshots in `docs/` and the README must never show the user's real runner names, Wi-Fi name or Mac name. Use the placeholders `northwind-traders`, `Contoso`, `Tailspin-Toys`, `Office-WiFi-5G` and `build-mac`.

## Release runner (public repo)

- The release job runs on `[self-hosted, macOS, ARM64]`. Only `Runner-Dashboard-builder` matches those labels: it's in `~/actions-runner-runner-dashboard` on the user's Mac and registered to this repo only. It uses that Mac's Xcode and the `gh` on its PATH. A release waits in the queue while the Mac sleeps.
- Any workflow run on it has the user's full access: the other runners' `.credentials`, keys, and the ability to install something that persists. Fork PRs bring their own workflow files, so:
  - The repo requires approval for every outside contributor's run (Settings › Actions › General › Fork pull request workflows: all outside collaborators). Keep it that way.
  - Never suggest approving a run without reading the PR's `.github/` changes.
  - Keep `release.yml` triggered only by tag push and `workflow_dispatch`, which outsiders can't trigger. No `pull_request` workflow may target this runner.
- macOS registers every app bundle it sees with Launch Services, and that includes CI and `dist/` builds. A leftover copy shares the bundle id, so macOS could open it instead of the installed app. The workflow's Clean up step runs `lsregister -u` on the build and deletes it. Do the same with local test builds.

## App updates (Sparkle)

- Installed apps read `SUFeedURL`, which is `releases/latest/download/appcast.xml`. That only works while the repo is public, and `scripts/install.sh` needs a public repo too.
- Sparkle compares `CFBundleVersion`, which `build.sh` sets to `<version>.<UTC build time>`, so the version decides. `--selftest` checks the format. History:
  - A pure timestamp broke this once: a local build in IST outranked a newer CI release built in UTC.
  - Changing the scheme strands every installed copy whose old number compares higher. Publish a release with the new scheme first, then reinstall local copies once.
- Sparkle checks every hour (`SUScheduledCheckInterval` 3600, which is Sparkle's minimum). Settings › Check for Updates… checks right away.
- A scheduled find shows the "Update available" banner instead of a window (gentle reminders, `Core/AppUpdater.swift`). "Update now" and Check for Updates… open Sparkle's own window, which handles download, install and relaunch.
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
- `scripts/install.sh` runs under macOS's bash 3.2. Keep its output ASCII: bash 3.2 reads a `…` right after `$VAR` as part of the variable name.
- Swift 5 language mode: the existing code doesn't build under Swift 6 strict concurrency.
- File-scoped state must stay in the same file as its users. That covers the top-level `private` caches (`runLinkCache`, `serviceLogCache`) and `Automation`'s `private(set)` properties, which the app-update extension sets.
- `UNUserNotificationCenter` crashes outside an app bundle, so guard on `Bundle.main.bundleIdentifier`.
- App icon: custom shapes only. SF Symbols aren't allowed in app icons.
- Stop always asks for confirmation: accidental clicks stopped runners before.

## Runner and system gotchas

- The dashboard shows `~/actions-runner*` plus the folders the user added with Find Runners (`Pref.addedRunners`). Nothing else is added automatically: the user asked for this.
- Find Runners (`Core/RunnerSearch.swift`, `Views/FindRunnersSheet.swift`) searches the whole Mac, every user's folders included, as far as this account can read.
  - A normal search runs when the sheet opens. It checks running `Runner.Listener` processes (`ps` shows every user's), then `actions.runner.*.plist` in every user's LaunchAgents and in `/Library/LaunchAgents` and `/Library/LaunchDaemons`, then Spotlight (`mdfind` for `Runner.Listener`). Spotlight covers indexed folders without permission prompts, Desktop and Documents included.
  - Hard search (the checkbox, applied on Retry) also walks the whole disk from `/` for `.runner` files, external volumes included. It skips `/System` (`/System/Volumes/Data` repeats every file), `/private`, `/dev`, every user's Desktop, Documents, Downloads and media folders (permission prompts), and hidden folders, packages, `Library`, `node_modules`, `Pods`, `DerivedData`, `build`, `_work` and `Backups.backupdb`. On the user's Mac it takes about 2 s.
  - Another user's runner (`isOtherUsers`, from the folder owner) can't be controlled from this account: Start, Stop, Restart and Clean are disabled for it.
  - To test what only hard search finds, use a folder ending in `.noindex`: Spotlight never indexes it.
  - Keep paths exactly as found, trimming only a trailing slash. `standardizingPath` and `resolvingSymlinksInPath` both turn `/private/tmp/…` into `/tmp/…`, and then the folder no longer matches the listener's path. The directory enumerator returns realpath-resolved URLs, so `walkForRunners` maps them back under the root it was given.
  - The radar sweeps for at least one turn, so a fast search still reads as a scan.
  - A runner started with `run.sh` has no `.service`, so `isService` is false and Start, Stop and Restart are disabled for it.
- Two `.sheet` modifiers on one view compete, and a sheet attached to a view that renders nothing (such as `AppUpdateBanner` with no update) never shows. In `OverviewView`, Add Runner's sheet is on the page and Find Runners' sheet is on the header.
- The listener spawns jobs from the versioned dir (`<runner>/bin.2.x.y/Runner.Worker`), not `<runner>/bin/`, so busy detection must match both.
- `gh` has no `admin:org` scope, so GitHub-side runner status isn't available. Everything comes from local files and processes.
- Add Runner (`Core/RunnerSetup.swift`, `Views/AddRunnerSheet.swift`) works like this:
  - The registration token comes from the pasted `./config.sh` line, since the app has no GitHub login.
  - It runs `config.sh` through the user's interactive login shell (`-ilc`). `config.sh` saves its PATH and tool variables to `.path`/`.env` for every job, and the app's own environment has no Homebrew, Java or Android SDK.
  - `svc.sh` must run from the runner folder, because it uses `pwd`. `run(_:_:in:)` takes the working directory.
  - It never passes `--replace`: a name clash must fail, not take over another machine's runner.
  - A failure before registration deletes the new folder. `configError` turns the common failures into a fix: an expired token is a 404 from `runner-registration`.
- `nettop -P -L 0` (per-runner network usage) has these quirks:
  - Run it on a pty: into a pipe it buffers output for minutes.
  - Its stdin must never hit EOF, or it spins at ~145% CPU.
  - `readabilityHandler` never fires on a pty master, so read it on a blocking thread.
  - Snapshot parent pids at 4 Hz, because short downloads finish between nettop samples.
- Data lives in `~/Library/Application Support/Runner Dashboard/`, for example `network-usage.json`, keyed by local hour start.

## Checking the UI from a terminal

- The terminal has Accessibility permission but not Screen Recording, so read the UI through System Events (`entire contents of window 1` of process "RunnerDash").
- An AX click doesn't open the MenuBarExtra panel. Post a CGEvent mouse click on the status item instead; System Events gives its position (`menu bar item 1 of menu bar 2`). Inside the panel (`group 1 of window 1`), AX clicks work. Find icon-only buttons by `help`, for example `first button … whose help is "Add Runner"`.
- Sheets are at `group 1 of sheet 1 of window "Runner Dashboard"`. SwiftUI text fields, including multi-line ones, appear as `text field`: fill them with `set value of`.
- Sparkle's windows are plain AppKit, so System Events can read their buttons ("Install Update", "Install and Relaunch").
- The user often uses the Mac while you test, so windows can close under you. Re-check that the window exists before assuming the app crashed: look at the PID and `~/Library/Logs/DiagnosticReports`.
- `log` is a zsh builtin: use `/usr/bin/log show`.
