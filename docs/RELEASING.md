# Releasing StreamSetu

Everything lives in this one repository: the source, the download files (GitHub Releases) and the Mac update feed (`appcast.xml` at the root).

| What | Tag | Made by | Where the files end up |
|---|---|---|---|
| Mac | `mac-v<version>` | `macos/Scripts/release-signed.sh <version> <build>`, then `BUILD=<build> macos/Scripts/publish-release.sh <version> "<notes>"` | `macos/dist/` (not in git). The release holds `StreamSetu-<version>.dmg` and `SHA256SUMS-<version>.txt`. The script also adds the release to `appcast.xml`. |
| Android phone, tablet, Fire TV, Android TV | `android-v<version>` | `android/publish-release.sh <version> <code> <notes file>` | `android/dist/<version>/` (not in git). The release holds `StreamSetu-FireTV-<version>.apk`, `StreamSetu-Android-<version>.apk` and `SHA256SUMS-<version>.txt`. |
| iPhone and iPad | TestFlight | `ios/Scripts/testflight.sh` | App Store Connect. |

Signing material is never in the repository: the Mac Developer ID certificate and notary profile are in the Keychain, the Sparkle update key is in the Keychain (account `streamsetu`), and the Android release key is in `~/Documents/keys/streamsetu-android/` (linked as `android/keystore.properties`, ignored by git).

After a release, update the download table in the top-level `README.md`.
