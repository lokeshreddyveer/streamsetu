# StreamSetu dev scripts

Build, test, install and check StreamSetu from one folder. Bash for macOS (3.2 compatible, `zsh -n` clean), each script with `set -euo pipefail`,
`--help`, argument validation, step logging with timings, `--dry-run` where it changes anything, and a lock so two runs of one script cannot collide.
Scripts call the existing release and verify scripts; they do not copy their logic. Key values are never printed (logs are masked, and `selftest.sh` checks it).

## Scripts

| Script | What it does |
|---|---|
| `mac-build.sh [version] [build]` | `macos/Scripts/build-release.sh` with libmpv bundled; default version is the last tag, build is kept while sources are unchanged; verifies Info.plist. Skips when sources, keys and version are unchanged (`--force`). |
| `mac-install.sh` | Signs (Developer ID found with `security find-identity`, or `--adhoc`), `codesign --verify --deep --strict`, secret scan, stops the app (SIGTERM, then waits for exit), backs up the old app to `$STREAMSETU_WORK/backup` (last 3), copies with `ditto` only if the binary or version differs, launches with `open -a`. `--no-launch`, `--wait`, `--rollback`. |
| `ios-build.sh [--simulator\|--device\|--generic]` | Regenerates the Xcode project only when the generator or file list changed, then `xcodebuild` with derived data in `$STREAMSETU_WORK/derived/ios-<mode>`. `-allowProvisioningUpdates` only for `--device`. Skipped when sources are unchanged. |
| `ios-install.sh` | `devicectl`: cached or only-paired device (`--device-id`), secret scan, install, launch. A locked phone gives exit 6 and "unlock the phone". `--build` builds first. Never runs UI tests on the phone. |
| `android-build.sh [--debug\|--test-apk\|--release-check]` | JDK 17, node on PATH, Gradle heap up to 5 GB (less on small Macs). `--test-apk` runs `android/release.sh <ver>-test`, apksigner verify, secret scan, sha256, copies to `~/Desktop/StreamSetu-android-test.apk`. Refuses to run beside another Gradle client unless `--force`. |
| `test-mac.sh [--all\|--filter X\|--ui]` | `macos/Scripts/run-tests.sh` with a stable scratch path; `--coverage`; `--ui` runs `macos/UITests/run-mac-uitests.sh`. |
| `test-ios.sh [--unit\|--ui\|--walk]` | Owns simulators `StreamSetu-dev-iPhone` / `-iPad` (created once, reused); `--cleanup` deletes only those. |
| `test-android.sh [--unit\|--lint\|--r8\|--all]` | One Gradle run, same guard. |
| `check-all.sh` | Cheap gates in parallel: host parity, fixtures, legal sync (one Python process), secret scan (cached), setu-guard check, `Scripts/smoke.sh` if present. `--full` adds the Atlas scan and release-gate tests. |
| `all-green.sh` | check-all, then Mac, Android and iOS unit tests concurrently (iOS after them below 24 GB RAM); PASS/FAIL table; logs in `$STREAMSETU_WORK/logs/<timestamp>/`; `--keep-going`. |
| `build-all.sh` | Mac, iOS simulator and Android debug builds, concurrent on 24 GB or more. |
| `commit-prep.sh` | Read-only: status grouped by area, setu-guard check, secret scan, flags files that must not be committed, prints suggested commit groupings. Never commits. |
| `bench.sh` | Cold vs warm timings (`--builds` adds no-op builds). |
| `selftest.sh` | Tests of the scripts themselves: syntax, `--help`, bad input, `--dry-run` for every script, locks, polling, job control, no sleeps, no key-shaped output. |

Common flags: `--help`, `--dry-run`, `--timings` (per-step table). Every script ends with one line: `OK in Ns` or `FAILED (exit N) after Ns`.

## Exit codes

0 ok, 1 a step failed, 2 usage, 3 missing requirement, 4 lock busy or another Gradle run active, 5 gate or secret scan failed, 6 device not ready.

## Speed rules

No fixed sleeps: waiting is polling every 50 ms with a timeout (`wait_until`). Stable caches under `$STREAMSETU_WORK` (default `~/Library/Caches/StreamSetu-dev`): derived data, SwiftPM scratch for tests, stamps (content hashes of sources) and the secret-scan cache (keyed on artifact, key files and tree). Nothing is cleaned unless you pass `--clean`. Independent stages run concurrently with a log each; the first failure cancels the rest unless `--keep-going`.
Limits: `macos/Scripts/build-release.sh` builds into `macos/.build` and `macos/dist` (it owns those paths), and regenerates the built-in key files on each real build; the stamp skips the whole build when nothing changed. `android/release.sh` does not take Gradle flags, so `--test-apk` relies on Gradle's own up-to-date checks plus the stamp.

## Requirements

Xcode 27.2 at `/Applications/Xcode.app` (override `DEVELOPER_DIR`); JDK 17 at `~/.local/opt/jdk-17/Contents/Home` (override `STREAMSETU_JAVA_HOME`); node in `~/.local/opt/node/bin`; Android SDK at `~/Library/Android/sdk` (`ANDROID_HOME`); `python3`; for the Mac UI tests `xcodegen` and Accessibility permission. Keys: folder `~/Documents/keys` (`STREAMSETU_KEYS_DIR`), folder mode 700, files mode 600, not in iCloud; files `tmdb-read-token.txt`, `fanart-api-key.txt`, `thetvdb-api-key.txt`. Android signing needs `android/keystore.properties`. Policy checks use `~/.config/setu-guard/check.py`.

## Typical workflows

- Before a commit: `Scripts/dev/check-all.sh`, then `Scripts/dev/commit-prep.sh`.
- Try the Mac app: `mac-build.sh && mac-install.sh --adhoc` (use `--rollback` to undo).
- Try on the phone: `ios-install.sh --build` (unlock the phone first).
- Android test APK: `android-build.sh --test-apk`.
- Everything: `all-green.sh --keep-going`. Check the scripts: `selftest.sh`.

## Troubleshooting

- Exit 4 "another run": a previous run is active, or stop it. A dead run's lock is reclaimed automatically. Gradle: `--force` to override.
- Exit 3 "no Developer ID": use `mac-install.sh --adhoc`, or install the certificate.
- Exit 6: unlock and trust the phone, check the cable; a stale cached id is dropped automatically (`$STREAMSETU_WORK/cache/ios-device-id`).
- A failing step prints its first error lines and the log path under `$STREAMSETU_WORK/logs/`.
- Force a rebuild: `--force`, or delete `$STREAMSETU_WORK/cache/stamps`.
- shellcheck is not installed on this Mac; `selftest.sh` runs `bash -n` and `zsh -n` and uses shellcheck when present (`brew install shellcheck`).

## Measured (this Mac, quiet tree, `bench.sh`)

| Step | Cold | Warm |
|---|---|---|
| check-all (cheap gates, parallel) | 1.7 s | 1.0 s |

Builds and tests were not timed here (heavy; other work was running). Use `bench.sh --builds` for no-op build times.
