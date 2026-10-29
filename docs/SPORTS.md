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

## Phase 3 (Android TV and Fire TV): playing a Sports feed

- Watch Best Feed and OK on a feed start the channel through `AppContainer.play`, the action Live TV uses. Sports has no player, surface or network path of its own; the one video surface is placed on the detail panel's picture box.
- One ranking (`SportsFeedRanker`) serves the button and the Recommended tag: the person's choice, the feed that played earlier this session, a feed the device is not known to be unable to show, preferred language, quality, preferred connection, known-healthy, provider order. Provider-supplied values outrank values read from names. Ranking reads memory only.
- Every request re-reads and re-authorizes the channel (source, library, profile, folder lock, adult filter, hidden, feed still part of the event). The play action reports how each request ended (started, refused, overtaken); only the newest request changes the screen.
- A failed switch starts the feed that was playing again through the same action ("Could not switch. Returned to the previous feed."). It never moves to an alternate feed by itself.
- A guide change never stops an allowed channel. If its event leaves the guide, the embedded picture stays with a notice; leaving that panel hands the stream to Live TV's embedded player without restarting it. Fullscreen is always the person's own action.
- Diagnostics are counts, durations and fixed words only.

## Phase 4 (Android TV and Fire TV): Multiview

- One Multiview implementation serves both the Sports builder and the ordinary Multi-View: `MultiviewSession` (one player per tile, the same `ExoEngine`, the Live TV resolver and the shared HTTP client), `MultiviewCapability` and `TileLimitPolicy` (the device's tile limit), and the shared authorization checks. Neither screen makes a player itself.
- The tile limit comes from what the device reports (hardware H.264 decoder, its instance count where Android says, memory class, cores). No hardware decoder means one picture, never several in software. A decoder-allocation failure lowers the limit for the rest of the session. A device that can show one picture has no Multiview and says so.
- Tiles start one at a time. A failed tile keeps its place and offers Try Again, Replace and Remove; the others keep playing. One tile has the sound; moving it never reloads a picture. Tile pictures are capped at 720p (540p with four tiles).
- An existing set longer than the limit is never started or shortened: the person chooses which to keep, and the set is left as it was.
- Changing a tile's feed uses the Phase 3 switch and restore rules for that tile alone. A change to who may see what checks each tile on its own. A guide change only detaches a tile from its event.
- Full Screen on a tile stops the tiles (the player cannot adopt a tile's engine), plays the channel, and returns to the builder.

## Phase 5 (Android TV and Fire TV): My Sports and reminders

- **Identity.** Follows and reminders are durable records of normalized facts (sport, kind, sides or event name, stage, competition), never the inferred event id. The id is kept only as the event a reminder is matched with right now. No stream address, login or guide description is stored.
- **Database.** Schema version 8 adds `sports_follows` and `sports_reminders` by an explicit migration (no destructive fallback). Both carry a profile id and are removed with the profile. Deleting a playlist or its guide does not touch them.
- **Follows** are profile-scoped, matched by normalized key, shown by the name first chosen, and checked against what the profile may see before they are saved. Following starts nothing. My Sports is the first filter once something is followed; inside each section reminded events come first, then followed sides, competitions and sports, then time. An event never changes section.
- **Reminders** are always explicit. After a guide refresh they are matched in one batch: same sport and identity, a compatible competition, and a start within three hours. The same sides twice in that window (a doubleheader) are never told apart by order or by who is nearer: a reminder keeps its fixture only if the channels that carried it and not the other still single out one fixture, or if exactly one fixture still starts where the reminder says. Otherwise (including two fixtures on the same channels after one of them moved) it is ambiguous, nothing is sent, and it stays pending; it is found again when it becomes provable. Low-confidence matches never associate silently.
- **Alarms** use the system alarm service the programme reminders use (`setAndAllowWhileIdle`, no exact-alarm permission), one per reminder, for the active profile only, and are set again after a restart, an app update or a time zone change. The system may delay an alarm to save power, so the in-app banner covers the time the app is open. A notification carries only the reminder id; the event is found and checked again inside the app, and no restricted title is ever shown.
- **Notification permission** (Android 13 and later) is asked for only when the first reminder is made. Fire TV often shows system notifications poorly, which is another reason for the banner.

## Phase 6 (Android TV and Fire TV): recording, Start Over and Catch-Up

- **One recorder.** Sports makes no recording engine, playback engine or catch-up address. Recording is `ScheduledRecordings` + `RecordService` (the code Guide recordings use); Start Over and Catch-Up are `StartOver.canOffer`, `CatchUpPlayable` and `StreamResolver` through the normal play action. A test scans the Sports sources for any of these.
- **Database.** Schema 9 adds `sports_recordings` by an explicit 8→9 migration (a failed migration leaves schema 8 usable). The Sports row owns identity, matching and state; it is linked to the executor by a generated schedule id, never by channel and start time. It stores no credentials, addresses, titles, descriptions or file paths, and is removed with the profile. A nullable `programmeId` column is reserved; it is not filled in (see limits).
- **Execution-time authorization** is shared by every scheduled recording, Sports or not. When the alarm fires only the id is read from the intent; the record is loaded by id and the profile, library, source, channel, folder lock, hidden channel, adult and kids rules are checked again. A missing, cancelled, finished, ambiguous or unauthorized record never starts; a repeated or stale alarm (after a reschedule or cancel) does nothing.
- **Cancel, Stop, Delete.** Cancel removes a schedule and creates no file. Stop finishes the recording and keeps the playable part. Delete stays a separate confirmed action in Settings → Recordings. A failed or interrupted recording keeps what was captured when it can be played.
- **Matching.** Same conservative evidence as reminders: a channel only one sibling event uses, else one start within five minutes with the others an hour or more away, else Review Required. A Review Required recording is never scheduled or started; it can be restored once the guide proves it again.
- **Formats.** HLS channels cannot be recorded. Xtream live now asks for the transport stream when the account allows it. When every authorized feed is HLS the event shows "Recording isn't supported for this stream format yet." and no Record action.
- **Space.** An estimate range from the inferred quality, labelled as an estimate. Recording is blocked only below the lowest estimate plus a 500 MB reserve, or when the folder is unavailable; an unsure case warns. It is checked again immediately before start. No other recording is ever deleted.
- **Connections.** One recording per provider unless the provider reported a limit, at most two on the device. Playback, Multi-View and recordings on the same provider all count. Nothing else is stopped to make room (`CONNECTION_LIMIT`, `DEVICE_RECORDING_LIMIT`).
- **Start Over / Catch-Up** are offered only for Xtream channels whose provider declared an archive that covers the programme; the programme is matched on the channel's own guide, with the guide offset applied. Focus never asks the provider for anything, and a failure never falls back to live.
- **Behaviour changes outside Sports.** Guide and phone recordings are tagged with the profile and go through the same check at start; the Settings action for a running recording is Stop (keeps the part) instead of Cancel.

### Limits

- No provider programme id is used; events the evidence cannot separate go to Review Required.
- A network failure after a recording has begun ends it clearly and keeps the part; it does not switch feeds.
- Needs a physical TV: exact-alarm and foreground-service behaviour on Android 12+ and Fire OS, Doze, reboot and time-zone changes, real provider connection limits and real free space.

## Phase 7 (Android TV and Fire TV): team and competition pages, My Sports, Search

Nothing new is stored and no engine is added. Pages, My Sports and Search results are made from the events the Sports service already builds, the person's own follows, reminders and recordings, and the guide. No web search, no scores, standings, rosters, logos or venues: a page shows only what the provider's guide says.

- **Identity.** Discovery and new follows use a strict identity: `v2:participant:<sport>:<name>` and `v2:competition:<sport>:<name>`. Case, accents, punctuation and repeated spaces are ignored; every word is kept, so "Barcelona" and "Barcelona SC", or "Athletic" and "Athletic Club", are two identities. The classifier's own key (which folds those words so two listings of one match meet) is unchanged: reminders and recordings still match by it and are never rewritten.
- **Shared names.** If the same exact name is carried by playlists that share no event, nothing shows it is one team, so the identities are scoped (`…@<playlist>`) and listed separately. A playlist pair that carries a common event is the evidence they mean the same thing; then the name is one identity. An ambiguous plain name matches nothing and says why; it is never merged to make a page look cleaner.
- **Old follows.** On load, against the guide this person may see: an old follow that fits exactly one strict identity is upgraded in one transaction (`replaceFollowKey`, race-safe, repeating it changes nothing); one that fits several stays as it is, matches nothing, and shows as "Choose the team" / "Choose the competition" in Manage My Sports; one that fits nothing is kept and shown as not in the guide. Nothing is deleted except by the person. The table is unchanged: the `v2:` prefix is part of `normKey`, and an old key is recognisable by not having it. No migration.
- **Pages.** A Team page: live, starting soon, upcoming, Catch-Up, the recordings and reminders for it, the number of channels, and Follow. A Competition page: live, starting soon, today, then each later local day in order, Catch-Up and recordings. Events listed by two playlists are one card. Cards open the existing event detail (Watch Best Feed, Start Over, Catch-Up, Record, Remind Me, Multiview, Open Guide). An event's detail links to its team and competition pages.
- **My Sports** stays inside the hub (the existing chip). In order: followed live, followed starting soon, recordings running, recordings scheduled, reminders, the rest of what is followed, recent Catch-Up. An event appears once, in the highest section that applies, with every mark. Recordings and reminders are the person's own and are listed whether or not their sides are followed. A recording whose event has left the guide stays reachable in a Recordings list there.
- **Catch-Up on pages** is loaded only when a page or My Sports needs it, back as far as the channels declare (at most three days), by the same service and the same authorization, kept apart from the hub's own events in a two-entry cache, cancelled when the page closes or who may see what changes. The page stays visible while it loads. General Search does not include Catch-Up events.
- **Search.** The existing Search list. The library's results are produced and shown exactly as before. Sports results are a second, independent lookup (`SportsSearch`) that merges into the same list when it arrives, in four groups after the library's own (Sports, Teams, Competitions, Sports recordings), using the ordinary result row. A failure or a cancelled lookup changes nothing already shown; a change to who may see what drops pending Sports results at once. Exact name beats a prefix beats a word match; inside each, followed, then live, then starting soon, then later. The index is built once per context and guide revision, off the main thread; a query only compares strings. Recordings are found through their event (a stored request keeps no title, by design). The phone's Search does not show Sports and its result order is unchanged.
- **Navigation.** Hub → Team/Competition page → event; Back goes event → page → the card it came from. Search → team, competition or event; Back returns to Search with its words and result position held by the Search session. Focus never opens, follows, loads, plays or asks a provider.
- **Windows.** One definition (`SportsWindow`): the hub, pages and Search ask the service for the same quarter-hour-aligned window, so they share cache entries.
- **Recordings in memory.** The screens read open recordings and the 100 most recently ended ones (one query), looked up by event in one map read per card.
- **Diagnostics** are counts, durations, cache hit or miss, outcome, failure category and the numbers of ambiguous and unclassified items. Never a name, a search text, an address or a path.

### Limits

- A name the classifier cannot read as sides or a competition is not a team or competition result; it is still found as an event or a TV Guide programme.
- A recording is listed on a page when it belongs to a listed event, or when its old key fits exactly one identity. Otherwise it is only in My Sports and Settings → Recordings.
- Catch-Up on a page needs a channel in the current guide window that declares an archive for that sport.
- Open Guide opens the Guide; it does not yet jump to the channel.
- The Multiview screen's "followed" hint uses follows without the scoping index.
- Needs a physical TV: remote feel on long names and large pages, cold-start time of the first Sports search, and memory on low-end Fire TV hardware.
