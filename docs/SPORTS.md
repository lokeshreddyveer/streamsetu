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
- A hidden channel, or one in a folder the person's restrictions hide, is removed before any event is built; it can never appear as a feed, and an event only such channels carried does not appear.
- The guide window is limited to 72 hours; work runs off the main thread, can be cancelled, and is cached by playlist guide revision, channel list, profile, restrictions and window. The cache is bounded (24 entries).
