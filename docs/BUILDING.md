[← Back to the README](../README.md)

# Building and repository layout

Compatibility, the folders of this repository, and the commands to build and test each app.

## Platforms and compatibility

| | Mac | iPhone and iPad | Android phone / tablet and Fire TV / Android TV |
|---|---|---|---|
| Language | Swift, SwiftUI, AppKit | Swift, SwiftUI | Kotlin, Jetpack Compose |
| Players | AVPlayer and mpv | AVPlayer and mpv, MPVKit | Media3 ExoPlayer and mpv |
| Formats | HLS and MP4 through AVPlayer; MKV, AVI, DASH, RTSP and unusual codecs through mpv | The same as the Mac | HLS, MP4, DASH and MPEG-TS through ExoPlayer; MKV, AVI and unusual formats through mpv |
| Minimum | macOS 14 | iOS 18 | Android 5.1, mpv needs Android 8 |

The Fire TV app has been developed and tested on a Fire TV Stick 4K (Fire OS 7). The Android phone layout has been tried on one Samsung phone running Android 16. Other devices should work but have not all been tested.

## Repository layout

| Folder | Contents |
|---|---|
| `macos/` | The Mac app and the release scripts, build, sign, notarize, publish, update feed |
| `web/` | The website (Next.js) and the privacy pages. `web/host.sh start` runs it at http://localhost:4300; each release refreshes it |
| `appcast.xml` | The update feed the Mac app reads |
| `docs/RELEASING.md` | Where each download comes from and how a release is made |
| `ios/` | The iPhone and iPad app, shares most code with the Mac app |
| `android/` | The Fire TV and Android TV app |
| `legal/` | Privacy policy and terms |
| `branding/` | Icons and artwork |

### Android modules

```
core-model        data classes, sorting and capability models
core-security     Android Keystore credential store
core-network      HTTP client, M3U / Xtream / XMLTV parsers
core-database     Room database (v6) plus the text-search index
core-preferences  settings and appearance preferences
core-media        playback coordinator, ExoPlayer and mpv engines, recovery policy
core-ui           shared motion timings, reduced-motion handling
data              repositories, sync, EPG, search, Stalker client, backup and maintenance
app               Hilt wiring, navigation, all screens, interface sounds
```

More detail is in [`android/ARCHITECTURE.md`](../android/ARCHITECTURE.md), and what is built against each specification is in [`android/SPEC-STATUS.md`](../android/SPEC-STATUS.md).

## Building

| Target | Command | Needs |
|---|---|---|
| Android, debug | `cd android && ./gradlew :app:assembleDebug` | JDK 17, Android SDK |
| Android, tests | `cd android && ./gradlew :app:testDebugUnitTest :data:testDebugUnitTest :core-network:testDebugUnitTest :core-media:testDebugUnitTest` | same |
| Android, signed release | `cd android && ./build-release.sh 0.13.0 130` (version name, version code) | your own `android/keystore.properties`, storeFile, storePassword, keyAlias, keyPassword. Without it the APK is debug-signed and for testing only. |
| Mac, tests | `cd macos && Scripts/run-tests.sh` | Xcode command line tools |
| Mac, release | `cd macos && Scripts/release-signed.sh 2.8.0 280` (builds, signs, notarizes) | libmpv in `macos/third_party/`, not in this repository, a Developer ID certificate, a notarization profile |
| iPhone and iPad | `python3 ios/Scripts/generate-project.py` makes the Xcode project; `ios/Scripts/testflight.sh <build>` archives and uploads to TestFlight | Xcode, an Apple developer account |
| A whole release | `MAC=2.8.0 MAC_BUILD=280 ANDROID=0.13.0 Scripts/release.sh <tag> docs/releases/<tag>.md` | the files above built first; see [docs/RELEASING.md](RELEASING.md) |
