# Release

```sh
Scripts/build-release.sh 1.0.0      # development app (universal by default; REDDY_ARCH=arm64|x86_64 builds one), ad-hoc signed → dist/StreamSetu.app
Scripts/create-dmg.sh               # dist/StreamSetu-1.0.0.dmg
Scripts/verify-release.sh           # signature, architectures, metadata, no stray paths or tool names
Scripts/generate-checksums.sh       # dist/SHA256SUMS.txt
```

## Distribution (signed + notarized)
Requires an Apple Developer Program membership.

```sh
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Scripts/build-release.sh 1.0.0
Scripts/sign-app.sh                                   # Hardened Runtime + entitlements
Scripts/create-dmg.sh                                 # signs the DMG too when SIGN_IDENTITY is set
xcrun notarytool store-credentials StreamSetu-NOTARY --apple-id you@example.com --team-id TEAMID   # once
NOTARY_PROFILE=StreamSetu-NOTARY Scripts/notarize-dmg.sh dist/StreamSetu-1.0.0.dmg
Scripts/verify-release.sh
```

Unsigned/ad-hoc builds open via right-click → Open (or `xattr -cr StreamSetu.app`).

## The two Mac downloads
A release has two disk images and no universal one: `StreamSetu-<v>-AppleSilicon.dmg` (arm64 only) and `StreamSetu-<v>-Intel.dmg` (x86_64 only). `Scripts/release-signed.sh <version> <build>` builds, signs, notarizes and packages both:
the Intel app is build `<build>` and the Apple silicon app is `<build>+1`. (`REDDY_ARCH=arm64|x86_64 Scripts/build-release.sh` builds one; `DMG_SUFFIX=-AppleSilicon|-Intel Scripts/create-dmg.sh` names it.)

**The update feed** (`appcast.xml`) has one item for each file. The Apple silicon item carries `sparkle:hardwareRequirements` = `arm64` (Sparkle 2.9 and later; the app ships 2.10) and the higher build, so an Apple silicon Mac is offered that file; an Intel Mac cannot take it and is offered the Intel item. An updater older than Sparkle 2.9 does not read that tag, so an Intel Mac on such a build could be offered the Apple silicon file: that is the one risk of two files, and why the oldest builds should be updated by hand once.

## libmpv (MKV / AVI / RTSP / DASH)
```sh
Scripts/fetch-libmpv.sh                    # once: downloads the universal libmpv/FFmpeg/libplacebo/libass stack
REDDY_BUNDLE_MPV=1 Scripts/build-release.sh 1.1.0
```
The bundle adds ~45 MB (DMG ≈ 51 MB). When signing for distribution, `sign-app.sh` signs every nested library first.
The stack contains GPL components: review the obligations before publishing. Without it StreamSetu runs fine and MPV is simply unavailable (MKV/AVI then show a clear message).

## Checklist
Tests pass · `verify-layering.sh` OK · version/build set · release notes in `Distribution/ReleaseNotes` · signed ·
notarized · stapled · checksums generated.

## Known limitations
- The Mac app is a Developer ID build that updates itself with Sparkle. There is deliberately no Mac App Store build or `STREAMSETU_APPSTORE` flag for the Mac: a Mac App Store version would need its own target without Sparkle, the Stalker portal type, the diagnostics uploader and the problem-report entries in the privacy manifest.
- Raw MPEG-TS support relies on the segmenter; exotic streams without PAT/PMT will not start.
- MKV/RTSP/DASH require libmpv.
- Sandboxed (App Store) distribution needs the sandbox entitlements file and a review of the loopback bridge.
