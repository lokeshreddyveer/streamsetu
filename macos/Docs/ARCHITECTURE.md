# Architecture

StreamSetu is a modular monolith: feature-based Clean Architecture with MVVM, built as one Swift package
(`Sources/REDDY`). It runs entirely on the Mac — no backend, no accounts.

```
Presentation   SwiftUI views · @Observable view models · PlaybackCoordinator-driven player UI
     │
Domain         Entities · protocols (repositories, SourceProvider, PlaybackEngine) · use cases
     │
Services       SourceManager · CatalogSyncService · EPGSyncService · SyncScheduler · SearchService
               DetailService · Favorites/History services · ArtworkService · PlaybackCoordinator · Diagnostics
     │
Data           HTTPClient · M3U/Xtream/XMLTV adapters · SQLite (DatabaseManager, repositories)
               Indexing (CatalogIndexer, SearchIndexer, normalizers) · ImageCache
     │
External       M3U playlists · Xtream-compatible APIs · XMLTV · user-authorized streams
```

## Rules

1. **The UI never downloads or parses.** Screens read the shared local catalog through repositories and services.
   `Scripts/verify-layering.sh` fails if SwiftUI is imported by Domain, Data, Services, Playback or Security.
2. **Nothing heavy runs on the main thread.** Downloads, parsing, indexing and queries run in detached tasks;
   view models publish results back on the main actor.
3. **A failed refresh never replaces a good catalog.** Data is downloaded and validated first, then committed in
   one transaction (see `CatalogIndexer`).
4. **User data survives refreshes.** Favorites, progress, hidden items, renames and guide assignments live in their
   own tables keyed by stable ids (`source | kind | provider id`), never by list position, name or stream URL.
5. **Sources are untrusted.** Size limits, record limits, URL scheme checks, XML entity expansion disabled,
   image validation and decompression-bomb guards.
6. **Playback state lives outside views.** `PlaybackCoordinator` owns the engines; channel switching swaps the
   item inside one long-lived `AVPlayer`, so no view or window is rebuilt.

## Concurrency

Swift 6 language mode with strict concurrency. Services that hold state are actors (`CatalogSyncService`,
`ImageCache`, `DetailService`) or `@unchecked Sendable` classes with explicit locking (`DatabaseManager`,
providers). View models and the coordinator are `@MainActor @Observable`.

## Source layout

`Application/` entry point, container, router, state, commands · `DesignSystem/` tokens, components, modifiers ·
`Domain/` entities, protocols, use cases · `Data/` network, sources, database, repositories, indexing, cache ·
`Services/` · `Playback/` · `Features/<Name>/{Views,ViewModels,Components,Models}` · `Security/` · `Utilities/`.
