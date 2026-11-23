import Foundation
import SwiftUI

#if DEBUG
/// The launch hook of the screen walk (gate c). Debug builds only: in a release build none of this exists.
///
///   `--atlas-walk`            every Atlas marker publishes a probe element (see AtlasProbe), and an empty library is filled with a small fixture playlist
///   `--atlas-open <atlas id>` opens that screen once the app is up (the same router calls the buttons use)
///   `--atlas-drop-declaration <id>`  leaves that entry out of the plan (proves the gate bites)
///   `--atlas-kids`           starts in kids mode
///   `--atlas-plan <path>`     writes what the Atlas declares for this device (screens, and the controls and settings on each) to that file
///
/// The UI test reads the plan, so the walk is generated from the Atlas and cannot drift from it.
@MainActor enum AtlasWalk {
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static let on = ProcessInfo.processInfo.arguments.contains("--atlas-walk")
    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// A fixed small library: a few folders of channels, films and series, so every tab has something to show and nothing needs a network.
    static func seed(_ c: AppContainer) {
        guard (try? c.catalog.sources())?.isEmpty ?? true else { return }
        let src = PlaylistSource(name: "Walk Playlist", type: .xtream, baseURL: "http://provider.example:8080", lastSync: Date().addingTimeInterval(-3600), syncStatus: "completed",
                                 capabilities: SourceCapabilities(live: true, movies: true, series: true, epg: false))
        do {
            try c.catalog.save(source: src)
            try c.catalog.saveCapabilities(src.capabilities, sourceID: src.id)
            func cat(_ kind: ContentKind, _ n: String, _ i: Int) -> CatalogCategory { CatalogCategory(id: "cat-\(kind.rawValue)-\(i)", sourceID: src.id, kind: kind, providerID: "\(kind.rawValue)\(i)", name: n, sortOrder: i) }
            let liveCats = ["News", "Sports", "Kids"].enumerated().map { cat(.channel, $0.element, $0.offset) }
            var channels: [Channel] = []
            for (gi, k) in liveCats.enumerated() { for j in 0..<4 {
                let n = gi * 4 + j, name = "\(k.name) Channel \(j + 1)", norm = MetadataNormalizer.normalize(name)
                channels.append(Channel(id: ItemID.make(source: src.id, kind: .channel, provider: "c\(n)"), sourceID: src.id, providerID: "c\(n)", name: name, normalizedName: norm, categoryID: k.id, categoryName: k.name,
                                        logoURL: nil, epgID: nil, language: nil, country: nil, resolutionHint: nil, sortOrder: n, streamRef: "http://x/c\(n).ts", groupKey: nil))
            } }
            try c.indexer.commitChannels(source: src, categories: liveCats, channels: channels)
            let movieCats = ["Action", "Drama"].enumerated().map { cat(.movie, $0.element, $0.offset) }
            var movies: [Movie] = []
            for (gi, k) in movieCats.enumerated() { for j in 0..<4 {
                let n = gi * 4 + j, title = "Walk Film \(n + 1)"
                movies.append(Movie(id: ItemID.make(source: src.id, kind: .movie, provider: "m\(n)"), sourceID: src.id, providerID: "m\(n)", title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: "A short story for the walk.", posterURL: nil, backdropURL: nil,
                                    releaseYear: 2020 + j, durationSeconds: 6000, genre: k.name, rating: "7.0", categoryID: k.id, categoryName: k.name, streamRef: "m\(n).mp4", addedAt: Date(), detailFetchedAt: nil))
            } }
            try c.indexer.commitMovies(source: src, categories: movieCats, movies: movies)
            let seriesCats = ["Drama Series"].enumerated().map { cat(.series, $0.element, $0.offset) }
            var shows: [Series] = []
            for n in 0..<4 {
                let title = "Walk Show \(n + 1)"
                shows.append(Series(id: ItemID.make(source: src.id, kind: .series, provider: "s\(n)"), sourceID: src.id, providerID: "s\(n)", title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: "A short series.", posterURL: nil, backdropURL: nil, genre: "Drama",
                                    releaseYear: 2022, rating: "7.5", categoryID: seriesCats[0].id, categoryName: seriesCats[0].name, addedAt: Date(), lastMetadataRefresh: nil))
            }
            try c.indexer.commitSeries(source: src, categories: seriesCats, series: shows)
        } catch { NSLog("atlas-walk: fixture failed: \(error)") }
    }

    /// Once the app is up: write the plan, then open the requested screen.
    static func ready(container c: AppContainer, router: IOSRouter, state: AppState) {
        if args.contains("--atlas-kids") { c.parental.kidsMode = true }          // a kids profile is in use: Setu must not be offered
        if let path = value(after: "--atlas-plan") { writePlan(to: path) }
        if let id = value(after: "--atlas-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { _ = AtlasOpener.open(id, container: c, router: router, state: state) }
        }
    }

    /// Everything the Atlas declares for iPhone and iPad: each screen (entry kinds screen and settingsPage), the entries whose parent path is that screen's path, and the ids of its controls that the source marks.
    static func writePlan(to path: String) {
        let phone = AtlasAssistant.platform
        // `--atlas-drop-declaration <id>` pretends that one declaration was deleted, to prove the walk notices (Scripts/check-atlas-walk.sh --prove).
        let dropped = value(after: "--atlas-drop-declaration")
        let visible = Atlas.entries.filter { !$0.platforms.isDisjoint(with: phone) && !$0.platforms.contains(.dmgOnly) && $0.id != dropped }
        struct Child: Codable { var id: String; var kind: String; var title: String }
        struct Screen: Codable { var id: String; var kind: String; var title: String; var path: [String]; var reach: String; var children: [Child] }
        var byParent: [[String]: [AtlasEntry]] = [:]
        for e in visible where e.kind == .setting || e.kind == .control { byParent[Array(e.path.dropLast()), default: []].append(e) }
        let screens = visible.filter { $0.kind == .screen || $0.kind == .settingsPage }.map { s in
            Screen(id: s.id, kind: s.kind.rawValue, title: s.title, path: s.path, reach: String(describing: s.reach),
                   children: (byParent[s.path] ?? []).map { Child(id: $0.id, kind: $0.kind.rawValue, title: $0.title) })
        }
        let all = visible.map { Child(id: $0.id, kind: $0.kind.rawValue, title: $0.title) }
        struct Plan: Codable { var platform: String; var screens: [Screen]; var entries: [Child] }
        let plan = Plan(platform: phone == .iPad ? "iPad" : "iPhone", screens: screens, entries: all)
        if let data = try? JSONEncoder().encode(plan) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
#endif
