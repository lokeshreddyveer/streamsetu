# StreamSetu Fire TV: status against the specifications

Branch `rewrite-architecture`. "Done" means it is built, compiles, and where logic is pure it has unit tests. **Nothing here has been run on a Fire TV yet**: the screens were last verified on the device before this rewrite.

## Architecture
| Spec item | State |
|---|---|
| Kotlin, Compose, MVVM, Room, Coroutines/Flow, Coil, Media3 + MPV fallback | Done |
| Hilt dependency injection | Done (`di/AppModule.kt`) |
| Retrofit | Dependency added, not used (the Xtream client is still hand-written OkHttp) |
| WorkManager | Dependency added, no background sync yet |
| DataStore | Not used: preferences are SharedPreferences behind typed `StateFlow`s |
| Modules | `core-model`, `core-security`, `core-network`, `core-database`, `core-preferences`, `core-media` (playback), `core-ui` (motion), `data` (repositories, sync, search, sort), `app` (UI). The brief's 18 feature modules are packages inside `app` (home, section, live, guide, detail, search, settings, library). |
| Android Keystore credentials | Done (existing) |

## Screens
| Spec | State |
|---|---|
| Choose Your Library at every launch (40/60, cached preview, no network on focus, long-press manage) | Done |
| First-time welcome (3 setup cards, continue previous setup, remote hint) | Done |
| Xtream / M3U URL / local M3U file, explicit Test, drafts, summary, combined libraries | Done |
| Compact expandable sidebar, hidden on Movies / Series / Live TV, Back hierarchy | Done |
| Home (header, ~40% banner slideshow, rows in the person's order, empty rows hidden) | Done |
| Movies / Series (folder panel, search folders, long-press menu, reorder, hide, lock + PIN, banner, shortcut chips, grid, Search / Filter / Sort / View) | Done |
| Fullscreen movie and series details (Resume / Start Over / Choose Stream / Continue Forward / Catch Up / gap warning / season selector / episode cards) | Done |
| Live TV 20/20/60 with preview player and fullscreen hand-off | Done |
| TV Guide timeline (now line, programme details, favorites filter, search, time shift) | Done |
| Settings: 13 categories, all controls functional or disabled with a reason | Done |
| Global search + section search (FTS, prefix, ranking, fuzzy rerank, history, suggestions) | Done |

## Playback
| Spec | State |
|---|---|
| Coordinator with typed state; UI never touches engines | Done (`PlaybackController`) |
| Separate Live / VOD buffering, per-connection overrides, per-connection engine | Done |
| Engine fallback retries the same stream; another provider stream only by choice | Done |
| Stall watchdog, retry policy, error classes (network, auth, DRM, decoder, format, timeout, refused) | Done |
| Home button / sleep: position saved, VOD paused, live closed after 20 s and restored | Done (not device-tested) |
| One-connection providers (`max_connections` or a learned refusal) are paced | Done |
| Diagnostics: engine, decoder, resolution, fps, buffer, dropped frames, startup time, errors | Done |
| Progress: verified-session checkpoints, no overwrite by a failed seek | Done |
| Surround passthrough, decoder fallback, subtitle size / background / outline | Done |
| Refresh-rate matching, audio delay, subtitle delay | Not offered (settings say why) |
| HDR / Dolby Vision | Reported only; played when the device supports it |
| Catch-up playback / timeshift | **Not built.** Channels that offer it are counted and shown. |
| Stale stream URL refresh for M3U tokens | **Not built.** Xtream URLs are built fresh each play. |
| Picture-in-Picture | Menu entry; unverified on Fire OS |

## Catalog
| Spec | State |
|---|---|
| Atomic refresh (catalog + index in one transaction; failure keeps the last catalog) | Done |
| FTS4 search index, rebuilt on demand, health shown | Done (FTS5 not available through Room) |
| Sorting with only honest options, per section and per folder, stable ties | Done |
| Folder lock covers lists, search, banners; PIN stored as salted hash; relock policy | Done |
| Combined libraries without copying catalogs; duplicate titles grouped in search, variants offered in details | Done |
| Capability model per connection (guide, catch-up, movies, series, live) | Partial: derived from delivered data and shown in Settings; per-stream capabilities (seek, tracks) come from the player |
| EPG matching by `epg_channel_id` only | Partial: no name matching, no multiple EPG sources, no retention limit yet |
| Duplicate-channel grouping | Not built |
| Local metadata overrides (artwork, titles) | Not built (folder labels only) |
| New-episode detection when a series gains an episode | **Not built** (needs a background refresh of watched series) |
| Custom / smart collections | Not built |
| Network-aware artwork loading | Not built |
| Background sync (WorkManager) | Not built |
| QR phone setup | Not built |

## Release
Backup / restore (versioned, validated, credentials excluded) is done. Signing, staged testing, crash diagnostics and distribution are not set up. Real-device frame-pacing and long-session tests have not been run.
