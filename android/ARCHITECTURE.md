# StreamSetu for Android TV and Fire TV

A native Kotlin app for Android TV, Google TV and Amazon Fire TV (Fire OS 5 and later, API 22+). It mirrors the Apple apps' ideas:
playlists in, one catalogue, one player with recovery, favourites and history kept on the device. No shared code with the Swift apps.

## Layout

```
android/
  core/   Android library, no UI. Everything that is not a screen.
  app/    The TV interface (Jetpack Compose) and the Activity.
```

### core
| Package | Role |
|---|---|
| `model` | Plain data classes: `Source`, `Channel`, `Movie`, `Series`, `Episode`, `EpgProgram`, `WatchProgress`, and the `Playable` family the player takes. |
| `parse` | `M3uParser` (streaming, tolerant), `Xtream` (addresses and lenient JSON reading), `XmltvParser` (guide, pull parser). Pure logic, unit tested. |
| `data.db` | Room database: entities, DAOs, `AppDatabase`. One table per kind, indices for category and search. |
| `data.repo` | `SourceRepository`, `CatalogRepository`, `UserRepository` (favourites, Watch Later, resume positions, play log, most-watched). The only way screens read data; all reads are `Flow`. |
| `sync` | `SyncService` reads a playlist into the database in one transaction (old rows are replaced only after the new ones were read). `EpgService` keeps a 48-hour guide window. |
| `net` | `Http` (one OkHttp client), `StreamResolver` (turns a stored reference into a playable address; Xtream logins are applied only here). |
| `security` | `CredentialStore` with an Android Keystore (AES-GCM) implementation. Passwords never reach the database or logs. |
| `playback` | `PlaybackController` (Media3 ExoPlayer, one instance), `PlaybackState`, and `RecoveryPolicy` (pure retry/back-off rules: live streams retried more than movies, refusals explained, waits for the network). |

### app
| Piece | Role |
|---|---|
| `StreamSetuApp` / `AppContainer` | Object graph built once; no DI framework. |
| `MainActivity` | Side rail, tab content, overlays, back handling. |
| `nav.Navigator` | Tabs (Home, Live TV, Movies, Series, Search, Settings) and overlays (player, add playlist, series detail). Back closes the top overlay, then returns to Home, then leaves. |
| `ui.screens` | One file per area. ViewModels expose `StateFlow`s built from the repositories. |
| `ui.components` | `Focusable` (focus ring + scale; everything the remote can land on), `PosterCard`, `TvButton`, `TvTextField`, `SideRail`. |
| `ui.theme.Tokens` | Colours and sizes. Same near-black / cyan / blue look as iPhone and Mac. Text is never below 14 sp (read from a sofa). |

## Data flow
```
playlist ──SyncService──▶ Room ──DAO Flow──▶ Repository ──▶ ViewModel StateFlow ──▶ Compose
remote OK ─▶ AppContainer.play(item, queue) ─▶ StreamResolver ─▶ PlaybackController ─▶ ExoPlayer
                                           └▶ UserRepository (play log, resume positions every 10 s)
```

## Playback rules (same priorities as the Apple apps)
* One player instance. Switching channel stops reading the old stream before the new one starts.
* Failure → `RecoveryPolicy` decides: retry with growing waits (1, 2, 4, 8, 15 s), or stop with a plain message.
  A 401/403/429/5xx is treated as "provider refused" (often a one-connection limit): two tries, then explained.
* No network → the player waits and resumes by itself when a network returns.
* Movies and episodes resume where they stopped; within 30 s of the end (or 95 %) counts as watched.
* Buffer: starts after 1.5 s of data, holds up to 60 s.

## Remote control
OK shows the bar (and pauses a movie when the bar is already visible). Left/Right skip 10 s in a movie. Up/Down change channel in a live list
(and step episodes in a series). Play/pause and fast-forward/rewind media keys work. Back closes the player.

## Built since the first version
Guide screen (now and next per channel, from the XMLTV guide; M3U `url-tvg` and Xtream `xmltv.php` are read after each sync), Favourites tab
(channels and Watch Later), audio / subtitle chooser (MENU), sleep timer, hide-adult-categories switch (on by default).

## Not built yet
1. Catch-up playback and a time-grid guide.
2. PIN protection for the adult switch.
3. Stalker portals, HDHomeRun, local files and WebDAV.
4. MPV engine for MKV/AVI where ExoPlayer cannot decode (ExoPlayer plays most MKV and MP4; AVI and exotic codecs are the gap).
5. Secure-DNS fallback for blocked server names (done on Apple; same idea fits `StreamResolver`).
6. Amazon Appstore listing; sideload the APK until then.

## Build and test
```
export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :core:testDebugUnitTest      # parsers and recovery policy
./gradlew :app:assembleDebug           # app/build/outputs/apk/debug/app-debug.apk
adb connect <fire-tv-ip>:5555 && adb install -r app/build/outputs/apk/debug/app-debug.apk
```
On a Fire TV: Settings → My Fire TV → Developer Options → ADB debugging (and Apps from unknown sources) → on.

## Verification status
Compiles; 13 unit tests pass (M3U/Xtream/XMLTV parsing, retry policy, parental words). Not yet run on a device or emulator.
