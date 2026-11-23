import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// ONE builder for the long-press (iPhone, iPad) and right-click (Mac) menu of a tile: the same items in the same order on every surface. The list is a pure function of the facts about the
/// title (`TileMenu.entries`), so it is tested as a table; the views below only draw it, and every item is also offered to VoiceOver as a custom action.
enum TileMenu {
    enum Kind: Equatable, Sendable { case continueWatching, title, channel }

    enum Action: String, Sendable, CaseIterable {
        case resume, play, watchPrivately, openDetails, openFolder, goToCast
        case favorite, watchLater, moveToFront, moveToEnd, collection
        case playNext, addToQueue, removeFromQueue
        case dontRecommend, share, hide, removeFromContinue
        case multiView, hideChannel, rename
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let action: Action
        let title: String
        let symbol: String
        var destructive = false
        /// The system draws these (a submenu, the share sheet): VoiceOver reaches them there.
        var isSystemControl: Bool { action == .collection || action == .share }
        var id: String { action.rawValue }
    }

    /// What decides which items a tile offers.
    struct Facts: Equatable, Sendable {
        var kind: Kind = .title
        var isFavorite = false, isWatchLater = false, inQueue = false
        var queueAvailable = true
        /// The folder the title is in, when it has one that can be opened.
        var folderName: String?
        var hasCast = false
        var canDismiss = true, canHide = true
        var canMultiView = false
        var canRename = false
    }

    static let favourites: String = {
        #if os(macOS)
        "Favorites"
        #else
        "Favourites"
        #endif
    }()

    /// Order: play, open, lists, queue, recommendation and hiding, share, then what removes things.
    static func entries(_ f: Facts) -> [Entry] {
        var e: [Entry] = []
        func add(_ a: Action, _ t: String, _ s: String, destructive: Bool = false) { e.append(Entry(action: a, title: t, symbol: s, destructive: destructive)) }
        switch f.kind {
        case .channel:
            add(.play, "Play", "play.fill")
            add(.watchPrivately, "Watch Privately", "eye.slash")
            add(.favorite, f.isFavorite ? "Remove from \(favourites)" : "Add to \(favourites)", f.isFavorite ? "heart.slash" : "heart")
            add(.collection, "Add to Collection", "square.stack")
            add(.share, "Share Link", "square.and.arrow.up")
            if f.canRename { add(.rename, "Rename…", "pencil") }
            if f.canMultiView { add(.multiView, "Add to Multi-View", "rectangle.split.2x2") }
            add(.hideChannel, "Hide Channel", "eye.slash.circle", destructive: true)
        case .continueWatching, .title:
            if f.kind == .continueWatching { add(.resume, "Resume", "play.fill") } else { add(.play, "Play", "play.fill") }
            add(.watchPrivately, "Watch Privately", "eye.slash")
            add(.openDetails, f.kind == .continueWatching ? "Open Title Page" : "View Details", "info.circle")
            if let folder = f.folderName { add(.openFolder, "In folder \(folder)", "folder") }
            if f.hasCast { add(.goToCast, "Go to Cast", "person.2") }
            add(.favorite, f.isFavorite ? "Remove from \(favourites)" : "Add to \(favourites)", f.isFavorite ? "heart.slash" : "heart")
            add(.watchLater, f.isWatchLater ? "Remove from Watch Later" : "Add to Watch Later", f.isWatchLater ? "bookmark.slash" : "bookmark")
            if f.isFavorite {
                add(.moveToFront, "Move to Front of \(favourites)", "arrow.up.to.line")
                add(.moveToEnd, "Move to End of \(favourites)", "arrow.down.to.line")
            }
            add(.collection, "Add to Collection", "square.stack")
            if f.queueAvailable {
                if f.inQueue { add(.removeFromQueue, "Remove from Queue", "text.badge.minus") }
                else { add(.playNext, "Play Next", "text.line.first.and.arrowtriangle.forward"); add(.addToQueue, "Add to Queue", "text.badge.plus") }
            }
            if f.canDismiss { add(.dontRecommend, "Don't Recommend This", "hand.thumbsdown") }
            add(.share, "Share Link", "square.and.arrow.up")
            if f.canHide { add(.hide, "Hide This Title", "eye.slash.circle", destructive: true) }
            if f.kind == .continueWatching { add(.removeFromContinue, "Remove from Continue Watching", "xmark.circle", destructive: true) }
        }
        return e
    }
}

/// What a surface supplies: how to play and open, and (when it can) the folder and the cast. Anything left nil is not offered.
struct TileMenuHandlers {
    var play: () -> Void = {}
    var playPrivately: () -> Void = {}
    var open: () -> Void = {}
    var openFolder: (() -> Void)?
    var goToCast: (() -> Void)?
    /// A list on screen should reload (a title was hidden or removed).
    var changed: () -> Void = {}
    /// The progress row id for Continue Watching (a movie's id, or an episode's), when it differs from the title's.
    var continueID: String?
    /// A list-specific removal ("Remove from Recently Watched"), always last.
    var removal: (title: String, action: () -> Void)?
}

/// Does what an entry says. Markers only: nothing here writes watch progress, resume points or history.
@MainActor struct TileMenuRunner {
    let container: AppContainer?
    let state: AppState
    let item: LibraryItem
    let kind: TileMenu.Kind
    let handlers: TileMenuHandlers

    func facts() -> TileMenu.Facts {
        var f = TileMenu.Facts(kind: kind)
        f.isFavorite = state.isFavorite(item.id); f.isWatchLater = state.isWatchLater(item.id)
        f.inQueue = container?.watchQueue.contains(item.id) ?? false
        f.queueAvailable = container?.watchQueue != nil
        if handlers.openFolder != nil, let n = item.categoryName, !n.isEmpty { f.folderName = FolderNaming.clean(n) }
        f.hasCast = handlers.goToCast != nil && (container?.metadata.hasSavedCast(item.id) ?? false)
        return f
    }

    private func buzz(_ success: Bool = false) {
        if success { Haptics.success() } else { Haptics.tap() }
    }

    func perform(_ a: TileMenu.Action) {
        guard let c = container else { return }
        buzz()
        switch a {
        case .resume, .play: handlers.play()
        case .watchPrivately: handlers.playPrivately()
        case .openDetails: handlers.open()
        case .openFolder: handlers.openFolder?()
        case .goToCast: handlers.goToCast?()
        case .favorite: state.toggleFavorite(item.id, kind: item.kind); handlers.changed()
        case .watchLater: state.toggleWatchLater(item.id, kind: item.kind); handlers.changed()
        case .moveToFront: state.moveFavorite(item.id, kind: item.kind, toFront: true)
        case .moveToEnd: state.moveFavorite(item.id, kind: item.kind, toFront: false)
        case .playNext: c.watchQueue.add(item, next: true); state.toasts.show("“\(item.title)” plays next", symbol: "text.line.first.and.arrowtriangle.forward")
        case .addToQueue: c.watchQueue.add(item); state.toasts.show("Added “\(item.title)” to the queue", symbol: "text.badge.plus")
        case .removeFromQueue: c.watchQueue.remove(item.id)
        case .dontRecommend:
            let profile = c.profiles.activeID, id = item.id
            if c.smartMix.dismiss(profile: profile, itemID: id) {
                buzz(true)
                state.toasts.show("Won't be recommended again", symbol: "hand.thumbsdown", kind: .success, duration: 8, actionTitle: "Undo") { c.smartMix.undismiss(profile: profile, itemID: id) }
            } else { state.toasts.show("This title can't be changed here", symbol: "exclamationmark.circle", kind: .info) }
        case .hide:
            let id = item.id, kindRaw = item.kind.rawValue, repo = c.favoritesRepo
            try? repo.hide(id, kind: kindRaw)
            state.catalogVersion += 1; handlers.changed(); buzz(true)
            state.toasts.show("“\(item.title)” is hidden", symbol: "eye.slash", kind: .success, duration: 8, actionTitle: "Undo") { [state] in try? repo.unhide(id); state.catalogVersion += 1; handlers.changed() }
        case .removeFromContinue:
            let id = handlers.continueID ?? item.id, repo = c.historyRepo
            try? repo.hideFromContinue(itemID: id)
            state.catalogVersion += 1; handlers.changed(); buzz(true)
            state.toasts.show("Removed from Continue Watching", symbol: "xmark.circle", kind: .success, duration: 8, actionTitle: "Undo") { [state] in try? repo.showInContinue(itemID: id); state.catalogVersion += 1; handlers.changed() }
        case .collection, .share, .multiView, .hideChannel, .rename: break          // drawn by the system or by the channel menu itself
        }
    }
}

/// The menu body: the entries, in order, with a divider before the group that removes things.
struct TileMenuContent: View {
    let item: LibraryItem
    var kind: TileMenu.Kind = .title
    var handlers = TileMenuHandlers()
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    var body: some View {
        let runner = TileMenuRunner(container: container, state: state, item: item, kind: kind, handlers: handlers)
        let list = TileMenu.entries(runner.facts())
        let firstDestructive = list.first { $0.destructive }?.action
        ForEach(list) { entry in
            if entry.action == firstDestructive { Divider() }
            switch entry.action {
            case .collection: CollectionMenu(itemID: item.id, kind: item.kind)
            case .share: ShareLinkButton(link: item.isSeries ? DeepLink.link(series: item.title) : DeepLink.link(movie: item.title), name: item.title)
            default:
                Button(LocalizedStringKey(entry.title), systemImage: entry.symbol, role: entry.destructive ? .destructive : nil) { runner.perform(entry.action) }
            }
        }
        if let r = handlers.removal { if firstDestructive == nil { Divider() }; Button(r.title, role: .destructive, action: r.action) }
    }
}

private struct TileMenuModifier: ViewModifier {
    let item: LibraryItem
    let kind: TileMenu.Kind
    let handlers: TileMenuHandlers
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content
            .contextMenu { TileMenuContent(item: item, kind: kind, handlers: handlers) }
            .accessibilityActions {
                // The same entries as custom actions (the system draws the submenu and the share sheet itself).
                let runner = TileMenuRunner(container: container, state: state, item: item, kind: kind, handlers: handlers)
                ForEach(TileMenu.entries(runner.facts()).filter { !$0.isSystemControl }) { entry in
                    Button(LocalizedStringKey(entry.title)) { runner.perform(entry.action) }
                }
                if let r = handlers.removal { Button(r.title, action: r.action) }
            }.atlas("context.tile.menu")
    }
}

extension View {
    /// The shared long-press / right-click menu (and VoiceOver actions) of a movie or series tile.
    func tileMenu(_ item: LibraryItem, kind: TileMenu.Kind = .title, handlers: TileMenuHandlers = TileMenuHandlers()) -> some View {
        modifier(TileMenuModifier(item: item, kind: kind, handlers: handlers))
    }
}

extension ContinueItem {
    /// The movie, or the series an episode belongs to: what the menu's list, queue and recommendation actions apply to.
    var libraryItem: LibraryItem {
        switch content { case .movie(let m): .movie(m); case .episode(_, let s): .series(s) }
    }
}


// MARK: channels (the same builder, the same order)

/// Where "Go to Cast" lands: the title page opens and its cast row is scrolled into view. Set just before the page is opened, taken by the page that shows that title.
@MainActor enum CastFocus {
    private(set) static var pending: String?
    static func request(_ itemID: String) { pending = itemID }
    /// True once for the title that asked.
    static func consume(_ itemID: String) -> Bool { if pending == itemID { pending = nil; return true }; return false }
    static let rowID = "cast-row"
}

/// The menu of a channel, from the same entry list as titles (`TileMenu.entries`, kind .channel).
struct ChannelMenuContent: View {
    let channel: Channel
    var onPlay: () -> Void
    var onMultiView: (() -> Void)?
    var onRename: (() -> Void)?
    var onChanged: () -> Void = {}
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    var body: some View {
        var f = TileMenu.Facts(kind: .channel)
        f.isFavorite = state.isFavorite(channel.id); f.canMultiView = onMultiView != nil; f.canRename = onRename != nil
        let list = TileMenu.entries(f)
        let firstDestructive = list.first { $0.destructive }?.action
        return ForEach(list) { entry in
            if entry.action == firstDestructive { Divider() }
            switch entry.action {
            case .collection: CollectionMenu(itemID: channel.id, kind: .channel)
            case .share: ShareLinkButton(link: DeepLink.link(channel: channel.name), name: channel.name)
            default: Button(LocalizedStringKey(entry.title), systemImage: entry.symbol, role: entry.destructive ? .destructive : nil) { run(entry.action) }
            }
        }
    }

    private func run(_ a: TileMenu.Action) {
        switch a {
        case .play: onPlay()
        case .watchPrivately: container?.playback.play(channel: channel, privately: true)
        case .favorite: state.toggleFavorite(channel.id, kind: .channel); onChanged()
        case .multiView: onMultiView?()
        case .rename: onRename?()
        case .hideChannel: try? container?.favoritesRepo.hide(channel.id, kind: "channel"); state.catalogVersion += 1; onChanged()
        default: break
        }
    }
}

#if os(macOS)
/// What a Mac surface supplies to the shared title menu.
@MainActor enum MacTileHandlers {
    static func make(_ item: LibraryItem, container: AppContainer?, toasts: ToastCenter, router: AppRouter) -> TileMenuHandlers {
        var h = TileMenuHandlers(play: { if let container { PlayActions(container: container, toasts: toasts).play(item) } },
                                 playPrivately: { if let container { PlayActions(container: container, toasts: toasts).play(item, privately: true) } },
                                 open: { PlayActions.open(item, router: router) })
        if let cat = item.categoryID { h.openFolder = { router.openFolder(item.isSeries ? .series : .movies, categoryID: cat) } }
        h.goToCast = { CastFocus.request(item.id); PlayActions.open(item, router: router) }          // the title page opens with its cast row in view
        return h
    }
}
#endif

#if os(macOS)
extension View {
    /// Right-click (and the menu key) on a title tile, from the shared builder with the Mac handlers.
    func macTileMenu(_ item: LibraryItem) -> some View { modifier(MacTileMenuModifier(item: item)) }
}
private struct MacTileMenuModifier: ViewModifier {
    let item: LibraryItem
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    func body(content: Content) -> some View {
        content.tileMenu(item, handlers: MacTileHandlers.make(item, container: container, toasts: state.toasts, router: router))
    }
}
#endif

/// The menu of a search result: a title or a channel, built by the shared builder when the menu opens (the item is read then, so a long list costs nothing). Folders, episodes and
/// programmes have no tile menu. The express lane is told when a title result has no picture.
struct SearchResultMenuModifier: ViewModifier {
    let result: SearchResult
    let handlers: (LibraryItem) -> TileMenuHandlers
    let playChannel: (Channel) -> Void
    @Environment(\.container) private var container

    private var itemID: String? { switch result.destination { case .movie(let id), .series(let id): id; default: nil } }

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .onAppear { if let id = itemID, (result.artworkURL ?? "").isEmpty { container?.artworkMatcher.prioritize([id]) } }
            .onDisappear { if let id = itemID { container?.artworkMatcher.cancelPriority([id]) } }.atlas("context.search.result")
    }

    @ViewBuilder private var menu: some View {
        switch result.destination {
        case .movie(let id):
            if let m = ((try? container?.catalog.movie(id: id)) ?? nil) { TileMenuContent(item: .movie(m), handlers: handlers(.movie(m))) }
        case .series(let id):
            if let s = ((try? container?.catalog.seriesItem(id: id)) ?? nil) { TileMenuContent(item: .series(s), handlers: handlers(.series(s))) }
        case .playChannel(let id):
            if let ch = ((try? container?.catalog.channel(id: id)) ?? nil) { ChannelMenuContent(channel: ch, onPlay: { playChannel(ch) }) }
        default: EmptyView()
        }
    }
}
