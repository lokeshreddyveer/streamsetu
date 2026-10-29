# StreamSetu Android, Fire TV and Android TV: what exists

Updated 25 October 2026 for release 0.19.0 and the work after it. This replaces an older status written when the app was a rewrite on the `rewrite-architecture` branch; most of what
that file called "not built" has since been built. The branch is `main`.

How to read it: **Built** means the code is in the source and compiles. **Tested** names the kind of test. **Device** says what has been tried on a real device: the only one used so far
is a Fire TV Stick 4K (Fire OS 7). Android TV (non-Fire), Fire OS 5 and 6, and Android phones and tablets have not been tested on real devices for this release.
Anything not listed here is not claimed.

## Verified in release 0.19.0

| Area | Built | Tested | Device |
|---|---|---|---|
| Cinema theme, auto-hiding rail, rails on Movies and Series, library switcher | Yes | Unit tests for the navigator, focus memory, left-edge and rapid input (Robolectric) | Fire TV Stick 4K: screens and navigation exercised by a scripted run; Guide scrolling measured |
| Series episode layouts (object by season, one list per season, flat list) | Yes | Unit tests (`XtreamEpisodesTests`) | Fire TV: Bigg Boss (Telugu) seasons 8, 9, 10 show |
| Guide rows with no data are focusable | Yes | Not unit-tested | Fire TV: 6 Down and 6 Right presses in about 3 s, none janky (was a 19 s freeze) |
| Back returns to the poster it left | Yes | Unit test of the saved return point | Fire TV: scripted check passes |
| Held direction keys are thinned | Yes | Unit tests (`DirectionThrottleTests`) | Fire TV: flood test, no freezes |

## Built after 0.19.0, not yet built into an APK or run on a device

- Profile switching stops playback, writes the resume point and waits for pending writes, closes Wi-Fi sync and locks folders again; the auto-relock interval is applied by the clock.
- Private watching writes no progress, history, statistics or per-title player choices.
- Playback of any catalog item is re-checked at the moment of playing (connection on, folder locked, adult folder hidden), including for `streamsetu://` links.
- MPV checks certificates by default; a connection can be set to trust its own certificate.
- Scheduled recordings: HLS refused, early ending reported as partial, Cancel stops the download and deletes the partial file, opening a screen does not mark a running recording as failed.
- Guide import is bounded (download size, unpacked size, expansion ratio, programme count, time).
- Backup restore reads and checks the whole file first and writes in one transaction; restoring or resetting settings restarts the app so they apply.
- Removing a connection is one transaction. "Erase all local data" stops what runs, wipes every table, preferences file, Keystore key and app file, checks nothing is left, then restarts.
- No SQL newer than SQLite 3.22 (a source scan test). Android 5.1 saves logins with a Keystore-wrapped key.
- DASH: the Media3 DASH module is now a dependency (no DASH stream has been played yet).

## Features that exist (not re-checked against a device in this pass)

Library chooser and setup (Xtream, M3U, local file and folder, Plex, Jellyfin, Emby, Stalker, tuners, WebDAV), combined libraries, Home, Movies, Series, details pages, Live TV with
preview, TV Guide, global and section search, favorites, Watch Later and collections, folder arrangement and locks with PIN, new-episode detection, channel manager, catch-up and
start-over, scheduled recordings, saved titles, reminders, statistics, backup and restore, profiles with kids limits, Wi-Fi sync between devices, phone-assisted setup, background
sync, screenshots, crash reports, update check, refresh-rate matching, audio and subtitle delay, Trakt, debrid links, your own AI, and the touch layout for phones and tablets.

## Not built or not working

- The Setu chat is not in the Android apps.
- Recording of HLS channels (they are refused with a message).
- No Windows app.
- Real-device tests are missing for Fire OS 5 and 6, Android TV (non-Fire), phones and tablets, long sessions, and every provider type.
- The release script runs every module's unit tests, lint and the dependency check; the connected (on-device) tests run only with `CONNECTED=1`.
