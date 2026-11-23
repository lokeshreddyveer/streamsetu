# Releasing StreamSetu

Everything lives in this one repository: the source, the download files (GitHub Releases) and the Mac update feed (`appcast.xml` at the root).

One release holds every app, named by date (for example `2026.10.14`). Its files are the Mac DMG, the two Android APKs and the Windows zips (x64 and arm64), and its notes have a section for each app plus the SHA-256 of every file. iPhone and iPad builds go to TestFlight and, once approved, the App Store; they are listed in the notes.

1. Mac: `macos/Scripts/release-signed.sh <version> <build>` (builds, signs, notarizes; the DMG lands in `macos/dist/`).
2. Android and Fire TV: `android/build-release.sh <version> <code>` (tests, signs; the APKs land in `android/dist/<version>/`).
3. iPhone and iPad: `ios/Scripts/testflight.sh`. The version (`VERSION` in `ios/Scripts/generate-project.py`) is the one people see; the build number in that file is only a placeholder, because the script passes the real build number (last uploaded + 1, or the one you give it) on the command line at archive time. The release notes name that build (for example `ios-1.3-build-78.md`).
4. Write `docs/releases/<tag>.md`: one section per app.
5. Windows (optional): the build runs in a private repository on GitHub's Windows machines; download its zip to `windows/native/dist/StreamSetu-Windows-<version>.zip`.
6. `MAC=<v> MAC_BUILD=<b> ANDROID=<v> [WINDOWS=<v>] Scripts/release.sh <tag> docs/releases/<tag>.md` uploads everything (the Windows zip too, when `WINDOWS` is set) and adds the Mac DMG to the update feed.

The same script refreshes the website in `web/` (version numbers and What's new) and restarts it on this Mac at http://localhost:4300 with `web/host.sh`. New features also need a line in `web/content/site.ts`, so the Features page and the home page stay true.

The Android apps find updates by looking for a release with an APK and reading the version from the file name.

Signing material is never in the repository: the Mac Developer ID certificate and notary profile are in the Keychain, the Sparkle update key is in the Keychain (account `streamsetu`), and the Android release key is in `~/Documents/keys/streamsetu-android/` (linked as `android/keystore.properties`, ignored by git).

`Scripts/release.sh` rewrites the download table in the top-level `README.md` for the new release and commits it. The feature table (`docs/FEATURES.md`) is edited by hand, in the same commit as the feature.

## Test builds (not releases)

A sideload test APK is built with a name that cannot be mistaken for a release and a version code above the last release, for example `0.28.0-test` with code `263` (the last release is 0.27.0, code 262):

    cd android && ./gradlew :app:assembleRelease -PappVersionName=0.28.0-test -PappVersionCode=263

It is signed with the normal release key (`android/keystore.properties`), scanned with `Scripts/check-no-secrets.sh`, and checked with `apksigner verify`. It is never copied into `android/dist`, never published, and never listed in the update feed. A real release uses `android/build-release.sh <version> <code>` and a code above every test build.
