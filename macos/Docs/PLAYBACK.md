# Playback

`PlaybackCoordinator` (main actor, outside any view) owns playback. The UI binds to its state and calls its
intents; engines sit behind `PlaybackEngine`.

## Engines

| Engine | Role | Status |
|---|---|---|
| **AVPlayer** | Primary: HLS, MP4/H.264/HEVC, and live MPEG-TS via the local HLS bridge | Implemented and verified against a real provider |
| **libmpv** | Secondary: MKV, AVI, RTSP, DASH, unusual codecs | Implemented and verified with a real MKV (plays, pauses, seeks, renders frames, reports codec/size, fails cleanly). Bundled via `Scripts/fetch-libmpv.sh` + `REDDY_BUNDLE_MPV=1` |

### MPEG-TS bridge
Many IPTV panels serve only raw `.ts`. `TSBridge` downloads the stream, cuts it into keyframe-aligned segments
(each prefixed with PAT/PMT, durations from PTS), and serves a rolling HLS playlist on `127.0.0.1` for AVPlayer.
`TSSegmenter` is pure and unit-tested with synthetic transport streams (keyframe cuts, forced cuts when an encoder
never flags keyframes, PTS wrap, resync after garbage, window size).

### libmpv
`MPVLibrary` searches the app bundle (`Frameworks/libmpv*.dylib`), then Homebrew paths (`REDDY_LIBMPV` overrides) and records why a load failed (shown in Diagnostics).
Frames are decoded by mpv (VideoToolbox where possible), rendered in software into pixel buffers and shown in an
`AVSampleBufferDisplayLayer`. `Scripts/fetch-libmpv.sh` downloads the universal (arm64 + x86_64) stack from the IINA release; `Scripts/bundle-libmpv.sh` embeds it and fixes the libraries' load paths. These builds include GPL components — review the licensing implications before distributing a bundle that contains them.

**Hardened Runtime:** mpv's built-in Lua scripting (LuaJIT) needs executable memory and is killed by macOS ("Invalid Page"), so `MPVConfiguration.isolationOptions` turns scripting and user config off. Verify any libmpv change with `Scripts/verify-mpv-hardened.sh <media>` and the app self-test: `REDDY_SELFTEST_MEDIA=<file> dist/StreamSetu.app/Contents/MacOS/StreamSetu`.

Opt-in engine test: `REDDY_LIBMPV=… REDDY_TEST_MEDIA=sample.mkv Scripts/run-tests.sh MPVEngineTests`.

## Engine selection
By container (detected from scheme, extension and path, not extension alone): HLS/MP4 → AVPlayer; MPEG-TS →
AVPlayer via the bridge; MKV/RTSP/DASH → MPV when available. Settings can force an engine. Engine switching is only
offered for unsupported formats and never to get around authorization or DRM.

## State machine
`idle → resolving → preparing → buffering ↔ playing ↔ paused / seeking → ended / failed`. Every transition goes through
`PlaybackStateMachine`; starting a new item is always legal (instant channel switching).

## Recovery
`PlaybackRecoveryService`: transient network failures retry up to 3 times with backoff and **re-resolve the stream URL**
(tokens may expire); unsupported formats may try the other engine once; “not found” retries once; authorization
failures are never retried. A stream that plays for 5 seconds earns a fresh retry budget.

## Errors shown to users
Network unavailable · stream format not supported · provider rejected the request · stream could not be reached ·
stream no longer available — never raw error codes, and logins are redacted from details.

## Features
Play/pause, seek (VOD), speed, volume/mute, audio and subtitle selection with preferred languages and subtitle style,
aspect (fit/fill), Picture-in-Picture and AirPlay (AVPlayer), screenshot, stream info overlay, resume, next episode,
mini-player, fullscreen, separate player window. Keys (when no text field has focus): Space, F, M, Esc, ←/→ ↑/↓
(fullscreen), Page Up/Down (channels).

## More features

- **Sleep timer** (`SleepTimer`, `SleepGuard`): stops after N minutes or at the end of the item; keeps the Mac awake while playing.
- **Radio mode:** audio-only presentation with artwork for streams that have no video.
- **Quality fallback** (`VariantFallback`): when a channel fails, the next quality variant of the same channel is tried.
- **Multi-view** (`MultiViewModel`): up to four AVPlayer tiles in their own window, one audible. Starting it stops the main player.
- **Catch-up:** Xtream `/timeshift/` URLs with a per-playlist clock offset.
- **Headers:** per-playlist User-Agent and headers reach AVPlayer, the TS bridge and libmpv alike.
