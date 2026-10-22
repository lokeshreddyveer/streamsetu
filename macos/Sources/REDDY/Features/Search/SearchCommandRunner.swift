import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Carries out a command chosen in the search box, on the Mac.
@MainActor enum SearchCommandRunner {
    /// Looks for a title by name: an exact (cleaned) name first, then a name that starts with the words.
    static func find(_ name: String, in c: AppContainer) -> (item: LibraryItem?, channel: Channel?) {
        let wanted = MetadataNormalizer.normalize(TraktItem.cleanTitle(name))
        guard wanted.count >= 2 else { return (nil, nil) }
        var q = VODQuery(); q.search = name; q.limit = 40; q.sort = .rating
        let movies = ((try? c.catalog.movies(q)) ?? []).map { LibraryItem.movie($0) }
        let series = ((try? c.catalog.series(q)) ?? []).map { LibraryItem.series($0) }
        let all = movies + series
        let norm = { (i: LibraryItem) in MetadataNormalizer.normalize(TraktItem.cleanTitle(i.title)) }
        if let hit = all.first(where: { norm($0) == wanted }) ?? all.first(where: { norm($0).hasPrefix(wanted) }) { return (hit, nil) }
        var cq = ChannelQuery(); cq.search = name; cq.limit = 20
        let channels = (try? c.catalog.channels(cq)) ?? []
        let ch = channels.first(where: { MetadataNormalizer.normalize($0.name) == wanted }) ?? channels.first(where: { MetadataNormalizer.normalize($0.name).hasPrefix(wanted) })
        return (nil, ch)
    }

    static func run(_ cmd: SearchCommand, container c: AppContainer, router: AppRouter, state: AppState) {
        func done() { router.clearSearch() }
        switch cmd.kind {
        case .go(let target, let library):
            switch target {
            case .discover: router.go(.home)
            case .tonight: router.navigate(.home, .shortcut(.tonight))
            case .liveTV: router.go(.liveTV)
            case .movies: router.go(.movies)
            case .series: router.go(.series)
            case .guide: router.go(.guide)
            case .favorites: router.go(.favorites)
            case .watchLater: router.navigate(.home, .shortcut(.watchLater))
            case .continueWatching: router.go(.continueWatching)
            case .recentlyWatched: router.navigate(.home, .shortcut(.recentlyWatched))
            case .history: router.navigate(.home, .shortcut(.watchHistory))
            case .collections: router.go(.collections)
            case .statistics: router.navigate(.home, .shortcut(.statistics))
            case .downloads, .settings:
                #if os(macOS)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                #endif
            }
            router.libraryQuery = library
            done()
        case .play(let name):
            let hit = find(name, in: c)
            if let item = hit.item { PlayActions(container: c, toasts: state.toasts).play(item); done() }
            else if let ch = hit.channel { c.playback.play(channel: ch); c.playback.isExpanded = true; done() }
            else { state.toasts.show("Nothing named “\(name)” in your library.", symbol: "magnifyingglass", kind: .warning) }
        case .resume:
            if let next = (try? c.history.continueWatching(limit: 1))?.first {
                switch next.content {
                case .movie(let m): c.playback.play(movie: m)
                case .episode(let e, let s): c.playback.play(episode: e, series: s)
                }
                done()
            } else { state.toasts.show("Nothing to resume yet.", symbol: "play.slash", kind: .info) }
        case .lastChannel:
            if let id = c.settings.lastChannelID, let ch = (try? c.catalog.channel(id: id)) ?? nil { c.playback.play(channel: ch); c.playback.isExpanded = true; done() }
            else { state.toasts.show("No last channel yet.", symbol: "dot.radiowaves.left.and.right", kind: .info) }
        case .favourite(let name, let on):
            guard let item = find(name, in: c).item else { state.toasts.show("Nothing named “\(name)” in your library.", symbol: "magnifyingglass", kind: .warning); return }
            if state.isFavorite(item.id) != on { state.toggleFavorite(item.id, kind: item.kind) }
            state.toasts.show(on ? "Added “\(item.title)” to Favorites." : "Removed “\(item.title)” from Favorites.", symbol: "heart", kind: .info)
        case .watchLater(let name, let on):
            guard let item = find(name, in: c).item else { state.toasts.show("Nothing named “\(name)” in your library.", symbol: "magnifyingglass", kind: .warning); return }
            if state.isWatchLater(item.id) != on { state.toggleWatchLater(item.id, kind: item.kind) }
            state.toasts.show(on ? "Added “\(item.title)” to Watch Later." : "Removed “\(item.title)” from Watch Later.", symbol: "bookmark", kind: .info)
        }
    }

    /// Carries out a suggestion from the assistant and says what really happened. A title is read from the catalog again and the parental state checked now; "played" means the stream is playing,
    /// not that it was asked for, and a stream that fails says why.
    static func execute(_ kind: AssistantProposal.Kind, container c: AppContainer, router: AppRouter, state: AppState) async -> AssistantOutcome {
        func load(_ id: String) -> LibraryItem? {
            (try? c.catalog.movie(id: id)).flatMap { $0 }.map { LibraryItem.movie($0) } ?? (try? c.catalog.seriesItem(id: id)).flatMap { $0 }.map { LibraryItem.series($0) }
        }
        func watch(_ key: String?) async -> AssistantOutcome { await AssistantPlaybackWatch.started(c.playback, expecting: key) }
        let locked = "That is in a locked folder. Unlock restricted content first."
        func toggle(_ item: LibraryItem, later: Bool, on: Bool) -> AssistantOutcome {
            if later { if state.isWatchLater(item.id) != on { state.toggleWatchLater(item.id, kind: item.kind) } } else { if state.isFavorite(item.id) != on { state.toggleFavorite(item.id, kind: item.kind) } }
            let now = later ? state.isWatchLater(item.id) : state.isFavorite(item.id)
            guard now == on else { return .failed("I could not update \(later ? "Watch Later" : "Favorites"). Try it from the title’s page.") }
            return .done((on ? "Added" : "Removed") + " “\(item.title)” " + (on ? "to " : "from ") + (later ? "Watch Later." : "Favorites."))
        }
        switch kind {
        case .command(let cmd):
            switch cmd.kind {
            case .go: run(cmd, container: c, router: router, state: state); return .done(nil)
            case .resume:
                guard let next = (try? c.history.continueWatching(limit: 1))?.first else { return .failed("There is nothing to resume yet.") }
                var key: String?
                switch next.content {
                case .movie(let m): c.playback.play(movie: m); key = m.id
                case .episode(let e, let s): c.playback.play(episode: e, series: s); key = e.id
                }
                return await watch(key)
            case .lastChannel:
                guard let id = c.settings.lastChannelID, let ch = (try? c.catalog.channel(id: id)) ?? nil else { return .failed("There is no last channel yet.") }
                guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed(locked) }
                c.playback.play(channel: ch); c.playback.isExpanded = true; return await watch(ch.id)
            case .play(let name):
                let hit = find(name, in: c)
                if let ch = hit.channel, hit.item == nil { guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed(locked) }; c.playback.play(channel: ch); c.playback.isExpanded = true; return await watch(ch.id) }
                guard let item = hit.item else { return .failed("Nothing named “\(name)” is in your library.") }
                guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed(locked) }
                PlayActions(container: c, toasts: state.toasts).play(item); return await watch(item.isSeries ? nil : item.id)
            case .favourite(let name, let on), .watchLater(let name, let on):
                guard let item = find(name, in: c).item else { return .failed("Nothing named “\(name)” is in your library.") }
                var later = false; if case .watchLater = cmd.kind { later = true }
                return toggle(item, later: later, on: on)
            }
        case .playItem(let id, let isChannel, let title):
            if isChannel {
                guard let ch = (try? c.catalog.channel(id: id)) ?? nil else { return .failed("“\(title)” is no longer in your library.") }
                guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
                c.playback.play(channel: ch); c.playback.isExpanded = true; return await watch(ch.id)
            }
            guard let item = load(id) else { return .failed("“\(title)” is no longer in your library.") }
            guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
            PlayActions(container: c, toasts: state.toasts).play(item); return await watch(item.isSeries ? nil : item.id)
        case .toggleList(let id, _, let later, let on, let title):
            guard let item = load(id) else { return .failed("“\(title)” is no longer in your library.") }
            guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
            return toggle(item, later: later, on: on)
        default: return .failed("That is not something this screen can run.")
        }

    }
}
