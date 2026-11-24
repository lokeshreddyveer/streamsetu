import Foundation
import SwiftUI
import Observation

/// The sections of the Podcasts sidebar.
enum PodcastsSection: String, CaseIterable, Identifiable, Sendable {
    case discover, following, recent, upNext
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .discover: "Discover"; case .following: "Following"; case .recent: "Recently Played"; case .upNext: "Up Next" }
    }
    var titleText: String {
        switch self { case .discover: "Discover"; case .following: "Following"; case .recent: "Recently Played"; case .upNext: "Up Next" }
    }
    var symbol: String {
        switch self { case .discover: "sparkles"; case .following: "heart"; case .recent: "clock"; case .upNext: "text.line.first.and.arrowtriangle.forward" }
    }
}

/// A page above the section's own page. The stack is what Back unwinds.
enum PodcastsRoute: Equatable, Sendable {
    case genre(PodcastGenre)
    case show(PodcastSubscription)
}

/// Where the person is inside Podcasts, as plain values.
struct PodcastsNav: Equatable, Sendable {
    var section = PodcastsSection.discover
    private(set) var stack: [PodcastsRoute] = []

    var top: PodcastsRoute? { stack.last }
    var canGoBack: Bool { !stack.isEmpty }
    mutating func select(_ s: PodcastsSection) { section = s; stack = [] }
    mutating func push(_ r: PodcastsRoute) { stack.append(r) }
    @discardableResult mutating func back() -> PodcastsRoute? { stack.popLast() }
}

enum PodcastsLoad<T: Equatable>: Equatable { case idle, loading, loaded(T), failed }

/// Everything the Podcasts screens do, with no layout. The main window, the sidebar and the bottom bar all read the one instance.
@MainActor @Observable
final class PodcastsHub {
    static let shared = PodcastsHub(service: PodcastService(defaults: .standard), catalog: PodcastCatalogService(), library: PodcastLibrary(defaults: .standard), player: nil)

    var service: PodcastService
    let catalog: PodcastCatalogService
    let library: PodcastLibrary
    let player: PodcastPlayer
    var nav = PodcastsNav()
    private(set) var following: [PodcastSubscription] = []
    private(set) var top: PodcastsLoad<PodcastCatalogResult> = .idle
    private(set) var genreResults: PodcastsLoad<PodcastCatalogResult> = .idle
    private(set) var genre: PodcastGenre?
    var term = "" { didSet { if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, oldValue != term { clearSearch() } } }
    private(set) var found: [PodcastSubscription] = []
    private(set) var searching = false
    private(set) var message: String?
    @ObservationIgnored private var remote: PodcastRemote?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var topTask: Task<Void, Never>?
    @ObservationIgnored private var genreTask: Task<Void, Never>?

    init(service: PodcastService, catalog: PodcastCatalogService, library: PodcastLibrary, player: PodcastPlayer?) {
        self.service = service; self.catalog = catalog; self.library = library
        self.player = player ?? PodcastPlayer(library: library)
        following = service.subscriptions()
    }

    /// Connects Podcasts to the running app: the same followed shows as the Files window, the library player that a podcast stops, services' media, the media keys.
    func attach(container: AppContainer, pauseServices: @escaping () -> Void) {
        service = container.podcasts; reloadFollowing()
        let playback = container.playback
        player.stopLibrary = { if playback.current != nil { playback.stop() } }
        player.pauseServices = pauseServices
        if remote == nil { let r = PodcastRemote(player: player, artwork: container.artwork); r.isLocked = { [weak container] in container?.appLock.isLocked ?? false }; remote = r }
    }

    var isSearchActive: Bool { searching || !found.isEmpty || message != nil }

    // MARK: following

    func reloadFollowing() { following = service.subscriptions() }
    func unfollow(_ s: PodcastSubscription) { service.unsubscribe(s.feedURL); reloadFollowing() }
    func isFollowing(_ s: PodcastSubscription) -> Bool { following.contains { $0.feedURL == s.feedURL } }
    func hasNew(_ s: PodcastSubscription) -> Bool { library.hasNewEpisode(s.feedURL) }

    /// Reads each followed show's feed for its newest episode date (the dot on its cover).
    func refreshFollowing() {
        let shows = Array(following.prefix(30))
        Task { [service, library] in
            for s in shows {
                guard let feed = try? await service.load(s.feedURL) else { continue }
                library.noteLatest(feed.episodes.compactMap(\.published).max(), for: s.feedURL)
            }
        }
    }

    // MARK: catalog

    func loadTop(refresh: Bool = false) {
        if case .loading = top { return }
        if !refresh, case .loaded = top { return }
        top = .loading
        topTask?.cancel()
        topTask = Task { [catalog] in
            let r = try? await catalog.top(refresh: refresh)
            guard !Task.isCancelled else { return }
            top = r.map { .loaded($0) } ?? .failed
        }
    }

    func openGenre(_ g: PodcastGenre) {
        nav.push(.genre(g)); genre = g; genreResults = .loading
        genreTask?.cancel()
        genreTask = Task { [catalog] in
            let r = try? await catalog.top(genre: g, limit: 50)
            guard !Task.isCancelled, genre == g else { return }
            genreResults = r.map { .loaded($0) } ?? .failed
        }
    }
    func retryGenre() { if let g = genre { nav.back(); openGenre(g) } }

    // MARK: navigation

    func open(_ s: PodcastSubscription) { nav.push(.show(s)) }
    func back() {
        nav.back()
        if case .genre(let g)? = nav.top { genre = g } else if nav.top == nil { genre = nil }
    }
    func select(_ s: PodcastsSection) { nav.select(s); genre = nil }

    // MARK: search

    func search() {
        let words = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        nav.select(.discover)
        message = nil; found = []; searching = true
        searchTask = Task {
            do {
                if let url = URL(string: words), url.scheme?.hasPrefix("http") == true {
                    let sub = try await service.subscribe(url)
                    guard !Task.isCancelled else { return }
                    reloadFollowing(); searching = false; term = ""; message = nil
                    open(sub)
                } else {
                    let r = try await service.search(words)
                    guard !Task.isCancelled else { return }
                    found = r; searching = false; if r.isEmpty { message = "No shows found." }
                }
            } catch {
                guard !Task.isCancelled else { return }
                searching = false; message = error.localizedDescription
            }
        }
    }

    /// The cross, Escape, or an emptied field: the results go, the request in flight is cancelled, and Discover shows again.
    func clearSearch() {
        searchTask?.cancel(); searchTask = nil
        searching = false; found = []; message = nil
        if term != "" { term = "" }
    }

    // MARK: playing

    func play(_ e: PodcastEpisode, of show: PodcastSubscription, showArtwork: URL?) { player.play(PodcastEpisodeRef(e, show: show, showArtwork: showArtwork)) }
}
