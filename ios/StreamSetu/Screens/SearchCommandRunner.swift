import SwiftUI

/// Carries out a command chosen in the search box, on iPhone and iPad.
@MainActor enum SearchCommandRunner {
    /// Looks for a title by name: an exact (cleaned) name first, then a name that starts with the words.
    static func find(_ name: String, in c: AppContainer) -> (item: LibraryItem?, channel: Channel?) {
        let wanted = MetadataNormalizer.normalize(TraktItem.cleanTitle(name))
        guard wanted.count >= 2 else { return (nil, nil) }
        var q = VODQuery(); q.search = name; q.limit = 40; q.sort = .rating
        let all = ((try? c.catalog.movies(q)) ?? []).map { LibraryItem.movie($0) } + ((try? c.catalog.series(q)) ?? []).map { LibraryItem.series($0) }
        let norm = { (i: LibraryItem) in MetadataNormalizer.normalize(TraktItem.cleanTitle(i.title)) }
        if let hit = all.first(where: { norm($0) == wanted }) ?? all.first(where: { norm($0).hasPrefix(wanted) }) { return (hit, nil) }
        var cq = ChannelQuery(); cq.search = name; cq.limit = 20
        let channels = (try? c.catalog.channels(cq)) ?? []
        return (nil, channels.first(where: { MetadataNormalizer.normalize($0.name) == wanted }) ?? channels.first(where: { MetadataNormalizer.normalize($0.name).hasPrefix(wanted) }))
    }

    static func run(_ cmd: SearchCommand, container c: AppContainer, router: IOSRouter, state: AppState) {
        func done() { router.query = "" }
        func missing(_ name: String) { state.toasts.show("Nothing named “\(name)” in your library.", symbol: "magnifyingglass", kind: .warning) }
        switch cmd.kind {
        case .go(let target, let library):
            router.pendingShelf = nil
            router.pendingLibraryQuery = library
            switch target {
            case .discover, .tonight: router.go(.home)
            case .liveTV: router.go(.live)
            case .movies: router.go(.movies)
            case .series: router.go(.series)
            case .guide: router.go(.guide)
            case .favorites: router.pendingShelf = "favourites"; router.go(.movies)
            case .watchLater: router.pendingShelf = "watchLater"; router.go(.movies)
            case .continueWatching, .recentlyWatched, .history, .collections, .statistics, .downloads: router.go(.library)
            case .settings: router.go(.settings)
            }
            if (target == .movies || target == .series) && library == nil { router.pendingLibraryQuery = "" }
            done()
        case .play(let name):
            let hit = find(name, in: c)
            if let item = hit.item {
                switch item {
                case .movie(let m): Play.movie(m, c)
                case .series(let s): Task { await Play.series(s, c, privately: false) }
                }
                done()
            } else if let ch = hit.channel { Play.channel(ch, queue: [ch], c); done() }
            else { missing(name) }
        case .resume:
            if let next = (try? c.history.continueWatching(limit: 1))?.first {
                switch next.content {
                case .movie(let m): Play.movie(m, c)
                case .episode(let e, let s): Play.episode(e, s, c)
                }
                done()
            } else { state.toasts.show("Nothing to resume yet.", symbol: "play.slash", kind: .info) }
        case .lastChannel:
            if let id = c.settings.lastChannelID, let ch = (try? c.catalog.channel(id: id)) ?? nil { Play.channel(ch, queue: [ch], c); done() }
            else { state.toasts.show("No last channel yet.", symbol: "dot.radiowaves.left.and.right", kind: .info) }
        case .favourite(let name, let on):
            guard let item = find(name, in: c).item else { missing(name); return }
            if state.isFavorite(item.id) != on { state.toggleFavorite(item.id, kind: item.kind) }
            state.toasts.show(on ? "Added “\(item.title)” to Favorites." : "Removed “\(item.title)” from Favorites.", symbol: "heart", kind: .info)
        case .watchLater(let name, let on):
            guard let item = find(name, in: c).item else { missing(name); return }
            if state.isWatchLater(item.id) != on { state.toggleWatchLater(item.id, kind: item.kind) }
            state.toasts.show(on ? "Added “\(item.title)” to Watch Later." : "Removed “\(item.title)” from Watch Later.", symbol: "bookmark", kind: .info)
        }
    }

    /// Carries out a suggestion from the assistant and says what really happened. A title is read from the catalog again and the parental state checked now; "played" means the stream is playing,
    /// not that it was asked for, and a stream that fails says why.
    static func execute(_ kind: AssistantProposal.Kind, container c: AppContainer, router: IOSRouter, state: AppState) async -> AssistantOutcome {
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
                case .movie(let m): Play.movie(m, c); key = m.id
                case .episode(let e, let s): Play.episode(e, s, c); key = e.id
                }
                return await watch(key)
            case .lastChannel:
                guard let id = c.settings.lastChannelID, let ch = (try? c.catalog.channel(id: id)) ?? nil else { return .failed("There is no last channel yet.") }
                guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed(locked) }
                Play.channel(ch, queue: [ch], c); return await watch(ch.id)
            case .play(let name):
                let hit = find(name, in: c)
                if let ch = hit.channel, hit.item == nil { guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed(locked) }; Play.channel(ch, queue: [ch], c); return await watch(ch.id) }
                guard let item = hit.item else { return .failed("Nothing named “\(name)” is in your library.") }
                guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed(locked) }
                switch item { case .movie(let m): Play.movie(m, c); case .series(let t): await Play.series(t, c, privately: false) }; return await watch(item.isSeries ? nil : item.id)
            case .favourite(let name, let on), .watchLater(let name, let on):
                guard let item = find(name, in: c).item else { return .failed("Nothing named “\(name)” is in your library.") }
                var later = false; if case .watchLater = cmd.kind { later = true }
                return toggle(item, later: later, on: on)
            }
        case .playItem(let id, let isChannel, let title):
            if isChannel {
                guard let ch = (try? c.catalog.channel(id: id)) ?? nil else { return .failed("“\(title)” is no longer in your library.") }
                guard c.assistantAccessAllowed(categoryID: ch.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
                Play.channel(ch, queue: [ch], c); return await watch(ch.id)
            }
            guard let item = load(id) else { return .failed("“\(title)” is no longer in your library.") }
            guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
            switch item { case .movie(let m): Play.movie(m, c); case .series(let t): await Play.series(t, c, privately: false) }; return await watch(item.isSeries ? nil : item.id)
        case .toggleList(let id, _, let later, let on, let title):
            guard let item = load(id) else { return .failed("“\(title)” is no longer in your library.") }
            guard c.assistantAccessAllowed(categoryID: item.categoryID) else { return .failed("“\(title)” is in a locked folder. Unlock restricted content first.") }
            return toggle(item, later: later, on: on)
        default: return .failed("That is not something this screen can run.")
        }

    }
}
