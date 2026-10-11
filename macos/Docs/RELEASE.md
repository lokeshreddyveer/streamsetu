# Release

```sh
Scripts/build-release.sh 1.0.0      # universal app (arm64 + x86_64), ad-hoc signed → dist/StreamSetu.app
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
- Updates are manual (Sparkle can be added later).
- Raw MPEG-TS support relies on the segmenter; exotic streams without PAT/PMT will not start.
- MKV/RTSP/DASH require libmpv.
- Sandboxed (App Store) distribution needs the sandbox entitlements file and a review of the loopback bridge.
