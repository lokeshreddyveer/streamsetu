# StreamSetu for iPhone and iPad

SwiftUI app (iOS 18+). It shares its engine with the Mac app: the platform-neutral Swift files of `../macos/Sources/REDDY`
(database, parsing, sync, search, guide, playback logic, settings) are compiled straight into this app; only the screens are
iOS-specific (`StreamSetu/`). Nothing is built in: you add your own M3U / Xtream playlists. Everything stays on the device.

## Run it on your iPhone (free Apple ID, no paid account)

1. iPhone: Settings → Privacy & Security → **Developer Mode** → on (the phone restarts).
2. Mac: open `ios/StreamSetu.xcodeproj` in Xcode, sign in with your Apple ID (Xcode → Settings → Accounts).
3. Select the **StreamSetu** target → *Signing & Capabilities* → tick *Automatically manage signing* → Team: your **Personal Team**.
   If Xcode says the bundle identifier is taken, change `app.streamsetu.ios` to something unique (e.g. `app.streamsetu.yourname`).
4. Plug the phone in, pick it as the run destination, press Run. First launch: iPhone Settings → General → VPN & Device
   Management → trust your Apple ID.
5. A free-account install expires after **7 days**; press Run again to renew it. Your library and logins stay.

To try it in the Simulator, install an iOS runtime first (Xcode → Settings → Components/Platforms → iOS).

## Layout

- `SharedSources.txt` — the Mac source files compiled into this app. Edit it, then run `python3 Scripts/generate-project.py`.
- `Scripts/generate-project.py` — writes `StreamSetu.xcodeproj` (no Xcode project editing by hand).
- `Scripts/check.sh` — builds for the iOS Simulator SDK and for a device (no signing), and the Mac app.
- `StreamSetu/` — iOS app: `Screens/` (Home, Live TV, Movies & Series, Search, Library), `Player/` (player, Picture in Picture,
  AirPlay, mini player), `Components/`.

## Rules for shared files

A file listed in `SharedSources.txt` is built by both apps. Anything that only exists on the Mac (AppKit, IOKit, libmpv, window
code) must sit inside `#if os(macOS)`. After editing a shared file run `Scripts/check.sh`.

## What is in it

Live TV (numbers, named lists, hide/rename), TV Guide (timeline, reminders, catch-up), Movies and Series, search, favourites and
collections, history, a full player (Picture in Picture, AirPlay, sleep timer, tracks, speed, swipe-to-zap, catch-up, radio
mode), Multi-View, per-playlist settings (login, guide address and time shift, catch-up clock, buffering, User-Agent and headers,
channel health check), themes and a custom theme editor, parental controls, statistics, TMDB artwork, backup and restore with
automatic backups, folder ordering, storage and maintenance, diagnostics, and Shortcuts/Siri actions ("Play BBC One in StreamSetu").

## Not in this version

libmpv-only formats (MKV, RTSP, AVI), live rewind (needs libmpv), per-channel volume/engine overrides, and the Mac's
multi-step channel manager (EPG mapping per channel).
