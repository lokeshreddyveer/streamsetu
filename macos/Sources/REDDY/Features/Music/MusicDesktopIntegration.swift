import SwiftUI
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#endif

// The desktop edges of Music: the window title, track-change notifications, the menu bar item, the keyboard monitor, and the view modifier that
// puts theatre mode and the shortcuts list on top of the Music screen. All of it is macOS only; the rules are plain functions.

enum MusicDesktopRules {
    static let appTitle = "StreamSetu Music"

    /// "Title - Artists" with an em dash, "Title" alone when there are no artists, the app name when nothing is playing.
    static func windowTitle(for t: MusicTrack?) -> String {
        guard let t else { return appTitle }
        let artists = t.artistLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return artists.isEmpty ? t.title : "\(t.title) \u{2014} \(artists)"
    }

    /// A notification shows only while no app window has focus, except when the song started on its own (a gapless advance or a room
    /// host change) and the focused option is on. A track the person just picked from a focused window never notifies, and neither does
    /// the track restored at launch.
    static func shouldNotify(change: MusicTrackChange, enabled: Bool, focusedOption: Bool, appFocused: Bool) -> Bool {
        guard enabled, change != .restored else { return false }
        if !appFocused { return true }
        return change == .gapless && focusedOption
    }
}

struct MusicShortcutsHelp: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Keyboard shortcuts").font(Typography.heading); Spacer(); Button("Done") { onDone() }.keyboardShortcut(.defaultAction).atlas("control.music.musicDone") }
            let rows = MusicShortcutTable.help(mac: true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .trailing)], spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Text(verbatim: r.0.title).font(Typography.body)
                    Text(verbatim: r.1).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary)
                }
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Put on the Music main view: theatre mode on top, the shortcuts list, and the in-app keyboard monitor (macOS).
struct MusicDesktopSurfaces: ViewModifier {
    let hub: MusicHub
    @Bindable private var state = MusicSurfaceState.shared
    #if os(macOS)
    @State private var monitor: MusicKeyboardMonitor?
    #endif

    init(hub: MusicHub) { self.hub = hub }

    func body(content: Content) -> some View {
        // Zoom scales the whole Music view; Refresh (F5) changes its identity so every page loads its data again.
        content
            .musicZoomed()
            .id(MusicReload.shared.generation)
            .overlay { if state.theatre && hub.player.current != nil { MusicTheatreView(hub: hub) { state.theatre = false }.transition(.opacity) } }
            .sheet(isPresented: $state.showShortcuts) { MusicShortcutsHelp { state.showShortcuts = false } }
            .onChange(of: hub.player.current == nil) { _, none in if none { state.theatre = false } }
            .onAppear {
                MusicDesktopIntegration.shared.attach(hub: hub)
                #if os(macOS)
                if monitor == nil {
                    var h = MusicShortcutHandler(hub: hub)
                    h.onSearch = { MusicChromeState.shared.showPalette.toggle() }
                    h.onToggleNowPlaying = { hub.expandedPlayer.toggle() }
                    h.onShowShortcuts = { state.showShortcuts.toggle() }
                    h.onEscape = {
                        if state.theatre { state.theatre = false; return true }
                        if hub.expandedPlayer { hub.expandedPlayer = false; return true }
                        return false
                    }
                    monitor = MusicKeyboardMonitor(handler: h, somethingPlaying: { hub.player.current != nil })
                }
                monitor?.start()
                #endif
            }
            .onDisappear {
                #if os(macOS)
                monitor?.stop()
                #endif
            }
    }
}

extension View {
    /// Theatre mode, the shortcuts list and the keyboard monitor for Music.
    func musicDesktopSurfaces(hub: MusicHub) -> some View { modifier(MusicDesktopSurfaces(hub: hub)) }
}

// MARK: integration

/// Hooks the player to the desktop: title, notifications, menu bar item and the global hotkeys. Safe to call `attach` again.
@MainActor
final class MusicDesktopIntegration {
    static let shared = MusicDesktopIntegration()
    private weak var hub: MusicHub?
    private var attached = false
    #if os(macOS)
    private let menuBar = MusicMenuBarItem()
    private var lastNotificationID: String?
    #endif

    func attach(hub: MusicHub) {
        guard !attached else { return }
        attached = true
        self.hub = hub
        let previous = hub.player.onCurrentChanged
        hub.player.onCurrentChanged = { [weak self] track, change in
            previous?(track, change)
            self?.trackChanged(track, change)
        }
        #if os(macOS)
        MusicGlobalHotkeys.shared.perform = { [weak hub] a in
            hub?.performGlobalHotkey(a, bringAppForward: { MusicMiniPlayerController.shared.showMainWindow() })
        }
        MusicGlobalHotkeys.shared.apply(hub.library.settings.player.globalHotkeys)
        observeSettings()
        menuBar.setVisible(hub.library.settings.player.menuBarItem, hub: hub)
        applyTitle(hub.player.current)
        #endif
    }

    private func trackChanged(_ track: MusicTrack?, _ change: MusicTrackChange) {
        #if os(macOS)
        applyTitle(track)
        guard let hub, let track else { return }
        let p = hub.library.settings.player
        if MusicDesktopRules.shouldNotify(change: change, enabled: p.trackNotifications, focusedOption: p.trackNotificationsFocused, appFocused: NSApp.isActive) {
            notify(track)
        }
        #endif
    }

    #if os(macOS)
    /// The main window's title follows the playing track while the setting is on. The mini player's title is never touched.
    func applyTitle(_ t: MusicTrack?) {
        guard let hub, hub.library.settings.player.windowTitleFollowsTrack else { return }
        let title = MusicDesktopRules.windowTitle(for: t)
        for w in NSApp.windows where w.canBecomeMain && !(w is NSPanel) && w.isVisible { w.title = title }
    }

    private func observeSettings() {
        guard let hub else { return }
        withObservationTracking {
            _ = hub.library.settings.player.menuBarItem
            _ = hub.library.settings.player.windowTitleFollowsTrack
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let hub = self.hub else { return }
                self.menuBar.setVisible(hub.library.settings.player.menuBarItem, hub: hub)
                self.applyTitle(hub.player.current)
                self.observeSettings()
            }
        }
    }

    private func notify(_ t: MusicTrack) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = MusicNotificationDelegate.shared }
        let c = UNMutableNotificationContent()
        c.title = t.title
        c.subtitle = t.artistLine
        if let album = t.album?.title, !album.isEmpty, !MusicCompilationArtist.isCompilation(album) { c.body = album }
        // One fixed identifier: a new song replaces the banner of the last one (so a day of listening is one banner, not a stack), and the thread keeps any that were
        // left by an older version together. It is a passive notification: no sound, and it never lights the screen.
        c.threadIdentifier = "music.nowplaying"
        c.interruptionLevel = .passive
        c.sound = nil
        let id = "music.nowplaying"
        lastNotificationID = id
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.getDeliveredNotifications { delivered in
            // Banners from earlier versions had one identifier per song; clear them once.
            let old = delivered.filter { $0.request.identifier.hasPrefix("music.track.") }.map(\.request.identifier)
            if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
        }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
    }
    #endif
}

#if os(macOS)
/// Lets a banner show even while the app is frontmost (the rules above decide whether to post one at all).
final class MusicNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MusicNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

#endif
