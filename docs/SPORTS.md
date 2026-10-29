# Sports events: how they are found and what an event id means

Sports events are derived from the channels and guide of the person's own playlists. Nothing is stored and no outside sports service is used: `SportsClassifier` decides from a guide listing and its channel whether it is a clear event and what shape (two sides, a race session, a tournament round, a fight card, or a generic event with a known competition and a specific final or match number). `SportsEventService` groups the feeds of one event and caches the result. The Swift code is in `macos/Sources/REDDY/Domain/Sports/` (shared with iOS and iPadOS); the Kotlin code is in `android/core-model/.../sports/` and `android/data/.../sports/`, with the database wiring in `android/app/.../sports/SportsAdapter.kt`. Both implement the same rules and are tested against the same fixtures.

## What an event id is for

An event's `id` is **inferred** from the guide: the normalized event identity, the UTC day of the event, and the event's place among the occurrences of that identity that day. It does not change when a feed appears or disappears, when a start time is corrected by a few minutes, or when a playlist is refreshed.

**Use it for:** list keys, focus restoration, scroll position and in-memory or session cache identity.

**Do not use it as the permanent identity** of anything the person creates or that is synchronised between devices: reminders, recordings, watch history for an event, or sync records. It can change if an event sitting on UTC midnight has its time corrected across that line, if the guide changes which day it is listed on, or if the playlist stops carrying an earlier occurrence of the same sides that day (the later one then becomes the first).

Those features need a **durable record** of their own that re-associates an event after guide corrections: store the normalized identity (`SportsClassifier.Match.identity`, which for two sides does not depend on their order), the competition, the participants and the start time at the moment it was saved, and match a later event by identity, a compatible competition and a start within a tolerance (the same rule the service uses to group feeds), not by `id`.

## Rules worth knowing

- Listings about sport are not events: news, studio shows, highlights, documentaries, replays and "sports channel" listings. A listing that only says "Cricket Live" is skipped, never guessed at.
- Language and quality are unknown unless the playlist says so. A language or quality read out of a title or a channel name is marked as a hint (`MetadataSource.parsedFromName`), never as provider data. The Android channel model carries neither, so there they are unknown unless a name says one.
- A channel is removed before any event is built, and can never appear as a feed, when the person hid it, when its folder is **locked with the PIN and not unlocked right now**, or (while the adult filter or kids mode is on) when its folder has an adult name. An event only such channels carried does not appear. On Android the locks are the app's own (`FolderRepository.lockedIds`): a folder unlocked with the PIN shows its events until it relocks, and it relocks when the profile is switched, when the library is left and after the relock time. (An earlier version of this page said Android had no PIN-locked folders. That was wrong.)
- Sports follows the **open library** exactly as Movies, Series and Live TV do: it reads the library's source ids as they are, and with no library open nothing is shown.
- The guide window is limited to 72 hours; work runs off the main thread, can be cancelled, and is cached by playlist guide revision, channel list, profile, restrictions and window. The cache is bounded (24 entries).

## The Sports Hub on Android TV and Fire TV (Phase 2, read-only)

`ui/screens/sports/`: `SportsHubUiState` and `SportsSections` (pure: sections, filters, card labels, detail), `SportsViewModel` (owns the selected filter, the detail and the content), `SportsScreen` (draws the prepared state; no database or classification work in a composable).

- **Sections:** Live Now (now inside the programme interval), Starting Soon (within two hours, not live), Today's Schedule (the rest of the user's local calendar day) and Upcoming (later, inside the 72-hour window). A finished event is not listed. A section with no events is not shown.
- **When the screen refreshes:** when the guide revision changes, the playlists change, the guide time offset changes, or Refresh/Retry is chosen. Ordinary refreshes keep the old content on screen while the new is built. **Never** because focus moved, a card became visible, the clock ticked, or the detail opened or closed.
- **Security-context changes clear the screen at once and rebuild:** a profile switch, a different open library, the adult filter or kids mode changing, a folder relock, a hidden channel, or a source removed or disabled. A result that was started before such a change is dropped.
- **Guide change signal:** `EpgDao.guideTouched()` reads one row and emits whenever the guide table is written; the ViewModel debounces the burst and then reads what it needs once.
- **Detail:** read-only. Language and quality read out of a title or channel name are marked "(inferred)"; nothing is shown as provider data unless the playlist supplied it. Playback from Sports is not wired.
