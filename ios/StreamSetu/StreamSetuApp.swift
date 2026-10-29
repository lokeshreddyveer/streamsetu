import SwiftUI
import UIKit
import AVFoundation
import Observation
import BackgroundTasks

@main
struct StreamSetuApp: App {
    @State private var coordinator = IOSCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { BackgroundRefresh.register() }

    var body: some Scene {
        WindowGroup {
            Group {
                switch coordinator.phase {
                case .starting:
                    ZStack { ColorTokens.background.ignoresSafeArea(); ProgressView() }
                case .failed(let message):
                    FailureView(message: message, inventory: { coordinator.inventoryOfDamagedLibrary() }, recover: { keep in Task { await coordinator.recoverLibrary(keepPersonalData: keep) } })
                case .ready:
                    if let c = coordinator.container, let s = coordinator.state {
                        RootView()
                            .scrollIndicators(.hidden)
                            .environment(c.settings).environment(s).environment(coordinator.router)
                            .environment(\.container, c).environment(\.artwork, c.artwork)
                            .environment(\.locale, c.settings.language.locale ?? Locale.current)
                            .onOpenURL { coordinator.open($0) }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .tint(coordinator.container?.settings.accent.color ?? ColorTokens.accentDefault)
            .task { CrashCollector.shared.start(); await coordinator.boot(); if let c = coordinator.container { WidgetBridge.shared.start(c); SharePlayService.shared.listen(c) { coordinator.open($0) } } }
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
            if let note = recoveryNote { s.toasts.show(note, symbol: "lifepreserver", kind: .warning); recoveryNote = nil }
            Task { await c.startCloudIfEnabled() }
            Task { try? await Task.sleep(nanoseconds: 20_000_000_000); c.startPeopleIndex() }
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

    /// Said once the library is open again after a recovery.
    private var recoveryNote: String?

    /// What a damaged library holds, for the confirmation that comes before starting fresh.
    func inventoryOfDamagedLibrary() -> DatabaseRecovery.Inventory { DatabaseRecovery.inspect(StorageService.databaseDirectory) }

    /// Moves the damaged library aside (never deletes it) and opens a new one; with `keepPersonalData` the playlists, favourites, lists, profiles, locks and history are copied into it.
    func recoverLibrary(keepPersonalData: Bool) async {
        phase = .starting
        do {
            let out = try DatabaseRecovery.recover(keepPersonalData: keepPersonalData)
            recoveryNote = keepPersonalData ? out.message : "A fresh library was started. The old one is kept in the Recovery folder."
        } catch {
            phase = .failed("The damaged library could not be moved aside (\(error.localizedDescription)). Nothing was changed.")
            return
        }
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
        if phase == .background { container?.playback.persistProgress(); BackgroundRefresh.schedule() }
        if phase == .active, let c = container { Task { await c.scheduler.appOpened() } }
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
        case .playChannel(let name)?: playChannel(named: name)
        case .playMovie(let title)?: playMovie(titled: title)
        case .findSeries(let title)?: router.query = title; router.go(.search)
        case .sleep(let m)?: container?.playback.startSleepTimer(minutes: m)
        default: break
        }
    }

    private func playChannel(named name: String) {
        guard let c = container else { return }
        let sid = state?.activeSourceID
        Task { @MainActor in
            let found = await Task.detached { () -> (Channel, [Channel])? in
                let list = (try? c.catalog.channels(ChannelQuery(sourceID: sid, search: name, collapseVariants: true, limit: 200))) ?? []
                let wanted = MetadataNormalizer.normalize(name)
                guard let best = list.first(where: { MetadataNormalizer.normalize($0.name) == wanted }) ?? list.first else { return nil }
                return (best, list)
            }.value
            if let (channel, queue) = found { Play.channel(channel, queue: queue, c) }
        }
    }

    private func playMovie(titled title: String) {
        guard let c = container else { return }
        let sid = state?.activeSourceID
        Task { @MainActor in
            let found = await Task.detached { () -> Movie? in
                let list = (try? c.catalog.movies(VODQuery(sourceID: sid, search: title, limit: 50))) ?? []
                let wanted = MetadataNormalizer.normalize(title)
                return list.first(where: { MetadataNormalizer.normalize($0.title) == wanted }) ?? list.first
            }.value
            if let movie = found { Play.movie(movie, c) }
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
    /// The screens and pages are defined once, with the rule for where each one opens (see PhoneRoutes).
    typealias Tab = PhoneTab
    var tab: Tab = .home
    /// Set by a title's page ("In folder …") and taken by Movies or Series, which then opens that folder.
    var pendingFolder: (kind: ContentKind, id: String)?
    /// Words typed in the top search for a list's own search box (filters and ordering are read from them there), and the shelf to show; each is used once.
    var pendingLibraryQuery: String?
    /// A title chosen in the assistant: the root view opens its page.
    var pendingAssistantItem: LibraryItem?
    var pendingShelf: String?
    /// On iPhone, Search, Guide, Library and Settings live inside the More tab so Movies and Series stay on the bar.
    typealias MoreRoute = PhoneMoreRoute
    var morePath: [MoreRoute] = []
    var compact = true
    /// True while the iPad sidebar is on screen (set by the root view); then every destination is a screen of its own.
    var sidebar = false

    /// Opens a screen. A page of More (Search, the TV Guide, Library, Playlists, Settings) is pushed onto the More tab's own stack; it is never replaced by the tab that holds a button for it.
    func go(_ t: Tab) {
        if sidebar { tab = t == .more ? .library : t; return }          // the iPad's sidebar lists every destination, so there is no More page to push onto
        let route = PhoneRoutes.resolve(t)
        tab = route.tab
        if let page = route.page { morePath = [page] }
    }
    var query = ""
    var presentAdd = false
    var showMultiView = false
    var pendingAdd: PendingAdd?
}

private struct FailureView: View {
    let message: String
    let inventory: () -> DatabaseRecovery.Inventory
    let recover: (_ keepPersonalData: Bool) -> Void
    @State private var confirmFresh = false
    @State private var held = DatabaseRecovery.Inventory()
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").appFont(34).foregroundStyle(.orange)
            Text("StreamSetu could not open its library").font(.headline)
            Text(message.loc).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Repair Library") { recover(true) }.buttonStyle(.borderedProminent)
            Button("Start Fresh…", role: .destructive) { held = inventory(); confirmFresh = true }.buttonStyle(.bordered)
            Text("Repair keeps your playlists, favourites, lists, profiles, locks and watch history, and reads the channels again from your playlists. The damaged library is never deleted: it is kept in the Recovery folder.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.background)
        .confirmationDialog("Start with an empty library?", isPresented: $confirmFresh, titleVisibility: .visible) {
            Button("Start Fresh", role: .destructive) { recover(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your playlists, favourites, lists, profiles, folder locks, watch history and resume points will no longer be in the app. Passwords stay in the Keychain, but you will need to add the playlists again.\n\nIn the damaged library: " + held.lines.joined(separator: ", ") + ".\n\nThe old library is kept in the Recovery folder, so it can still be recovered.")
        }
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
