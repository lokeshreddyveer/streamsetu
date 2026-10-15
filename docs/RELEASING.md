# Releasing StreamSetu

Everything lives in this one repository: the source, the download files (GitHub Releases) and the Mac update feed (`appcast.xml` at the root).

One release holds every app, named by date (for example `2026.10.14`). Its files are the Mac DMG and the two Android APKs, and its notes have a section for each app plus the SHA-256 of every file. iPhone and iPad builds go to TestFlight and are listed in the notes.

1. Mac: `macos/Scripts/release-signed.sh <version> <build>` (builds, signs, notarizes; the DMG lands in `macos/dist/`).
2. Android and Fire TV: `android/build-release.sh <version> <code>` (tests, signs; the APKs land in `android/dist/<version>/`).
3. iPhone and iPad: `ios/Scripts/testflight.sh`.
4. Write `docs/releases/<tag>.md`: one section per app.
5. `MAC=<v> MAC_BUILD=<b> ANDROID=<v> Scripts/release.sh <tag> docs/releases/<tag>.md` uploads everything and adds the Mac DMG to the update feed.

The Android apps find updates by looking for a release with an APK and reading the version from the file name.

Signing material is never in the repository: the Mac Developer ID certificate and notary profile are in the Keychain, the Sparkle update key is in the Keychain (account `streamsetu`), and the Android release key is in `~/Documents/keys/streamsetu-android/` (linked as `android/keystore.properties`, ignored by git).

After a release, update the download table in the top-level `README.md`.
