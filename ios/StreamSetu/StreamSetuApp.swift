import SwiftUI
import UIKit
import AVFoundation
import Observation

@main
struct StreamSetuApp: App {
    @State private var coordinator = IOSCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch coordinator.phase {
                case .starting:
                    ZStack { ColorTokens.background.ignoresSafeArea(); ProgressView() }
                case .failed(let message):
                    FailureView(message: message) { Task { await coordinator.resetDatabaseAndRetry() } }
                case .ready:
                    if let c = coordinator.container, let s = coordinator.state {
                        RootView()
                            .scrollIndicators(.hidden)
                            .environment(c.settings).environment(s).environment(coordinator.router)
                            .environment(\.container, c).environment(\.artwork, c.artwork)
                            .onOpenURL { coordinator.open($0) }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .tint(coordinator.container?.settings.accent.color ?? ColorTokens.accentDefault)
            .task { CrashCollector.shared.start(); await coordinator.boot() }
            .onChange(of: scenePhase) { _, phase in coordinator.scenePhaseChanged(phase) }
        }
    }
}

/// Starts the app: builds the shared object graph and begins syncing.
@MainActor @Observable
final class IOSCoordinator {
    /// One instance for the whole process, so Siri and Shortcuts actions use the same library and player as the app.
    static let shared = IOSCoordinator()
    private var booting = false
    enum Phase { case starting, ready, failed(String) }
    private(set) var phase: Phase = .starting
    private(set) var container: AppContainer?
    private(set) var state: AppState?
    let router = IOSRouter()

    func boot() async {
        if booting { while container == nil, case .starting = phase { try? await Task.sleep(nanoseconds: 100_000_000) }; return }
        guard container == nil else { return }
        booting = true
        let clock = ContinuousClock(), began = clock.now
        var marks: [String: Int] = [:]
        func mark(_ name: String) { let d = began.duration(to: clock.now); marks[name] = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        do {
            // Playback category: sound plays with the silent switch on, and continues in the background and in Picture in Picture.
            // (Activating the session can block, so it is done off the main thread.)
            Task.detached(priority: .utility) {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
            }
            let c = try AppContainer()
            mark("library opened")
            container = c
            let s = AppState(container: c)
            state = s
            c.parental.onChange = { [weak s] in s?.reloadFolders(); s?.catalogVersion += 1 }
            await s.start()
            mark("library read")
            c.onCloudChange = { [weak s] r in
                s?.reload(); s?.catalogVersion += 1
                for id in r.newSources { if let u = UUID(uuidString: id) { s?.sync(u) } }
            }
            Task.detached { [artwork = c.artwork] in await artwork.trim() }
            mark("ready")
            UserDefaults.standard.set(marks, forKey: "startup.timings")
            phase = .ready                                  // the app opens now; iCloud starts in the background, it is never waited for
            Task { await c.startCloudIfEnabled() }
            c.autoBackup.runIfDue()
            resumeLastChannelIfWanted(c, s)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// With "Resume the last channel" on, starts the channel that was playing when the app was closed (only if it still exists).
    private func resumeLastChannelIfWanted(_ c: AppContainer, _ s: AppState) {
        guard c.settings.resumeLastChannel, !s.needsOnboarding, let id = c.settings.lastChannelID else { return }
        Task { @MainActor in
            let found = await Task.detached { () -> Channel? in
                var q = ChannelQuery(); q.collapseVariants = false; q.ids = [id]
                guard let ch = (try? c.catalog.channels(q))?.first, let source = try? c.catalog.source(id: ch.sourceID), source.enabled else { return nil }
                return ch
            }.value
            if let ch = found, c.playback.current == nil { c.playback.play(channel: ch, queue: [ch]) }
        }
    }

    func resetDatabaseAndRetry() async {
        try? FileManager.default.removeItem(at: StorageService.databaseDirectory)
        phase = .starting
        booting = false
        await boot()
    }

    private let lockWindow = LockWindow()

    func scenePhaseChanged(_ phase: ScenePhase) {
        if let lock = container?.appLock {
            if phase == .background { lock.appLeft() }
            if phase == .active { lock.appReturned() }
            // Covered as soon as the app stops being active, so the app switcher never shows the library while it is locked.
            lockWindow.show(lock.enabled && (lock.isLocked || phase != .active), lock: lock)
        }
        if phase == .background { container?.playback.persistProgress() }
        if phase == .active { container?.cloud.poke(); Task { await container?.cloud.syncNow() } }
        if phase == .background { container?.cloud.poke() }
    }

    /// `streamsetu://add?url=…` opens the Add Playlist form (it never adds anything by itself); a playlist file opened from
    /// Files does the same; `streamsetu://search?q=…` opens Search.
    func open(_ url: URL) {
        if url.isFileURL, LocalMedia.isVideo(url.lastPathComponent) { FilesPlayer.open(url, container: container); return }
        if url.isFileURL { router.pendingAdd = .file(url); router.presentAdd = true; return }
        switch DeepLink.parse(url) {
        case .addPlaylist(let address, let name)?: router.pendingAdd = .address(address, name: name); router.presentAdd = true
        case .search(let q)?: router.query = q; router.go(.search)
        case .openTab(let t)?: router.go(IOSRouter.Tab(t))
        case .remote(let command)?: remote(command)
        default: break
        }
    }

    private func remote(_ command: DeepLink.RemoteCommand) {
        guard let p = container?.playback else { return }
        switch command {
        case .pause: p.pause()
        case .resume: p.resume()
        case .stop: p.stop()
        case .next: p.nextChannel()
        case .previous: p.previousChannelInList()
        case .last: p.lastChannel()
        }
    }
}

/// Navigation state for the iOS interface.
@MainActor @Observable
final class IOSRouter {
    enum Tab: Hashable {
        case home, live, guide, movies, series, search, library, playlists, settings, more
        init(_ t: AppTab) {
            switch t { case .home: self = .home; case .liveTV: self = .live; case .guide: self = .guide; case .movies: self = .movies; case .series: self = .series }
        }
    }
    var tab: Tab = .home
    /// On iPhone, Search, Guide, Library and Settings live inside the More tab so Movies and Series stay on the bar.
    enum MoreRoute: Hashable { case search, guide, library, playlists, settings }
    var morePath: [MoreRoute] = []
    var compact = true

    func go(_ t: Tab) {
        let route: MoreRoute?
        switch t { case .search: route = .search; case .guide: route = .guide; case .library: route = .library; case .playlists: route = .playlists; case .settings: route = .settings; default: route = nil }
        if compact, let route {
            switch route {
            case .guide: tab = .live                      // the guide is opened from Live TV's top bar
            case .search: tab = .home                     // and search from Home's
            default: tab = .more; morePath = [route]
            }
        } else { tab = t }
    }
    var query = ""
    var presentAdd = false
    var showMultiView = false
    var pendingAdd: PendingAdd?
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").appFont(34).foregroundStyle(.orange)
            Text("StreamSetu could not open its library").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Rebuild Library and Retry", action: retry).buttonStyle(.borderedProminent)
            Text("Your playlists are re-added from their sources; nothing on the server changes.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background)
    }
}

/// The lock cover lives in a window of its own, above everything: sheets and the full-screen player included.
@MainActor final class LockWindow {
    private var window: UIWindow?
    func show(_ on: Bool, lock: AppLock) {
        if on {
            guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.rootViewController = UIHostingController(rootView: LockScreen(lock: lock, onUnlock: { [weak self] in self?.show(false, lock: lock) }))
            w.isHidden = false
            window = w
        } else {
            window?.isHidden = true; window = nil
        }
    }
}
