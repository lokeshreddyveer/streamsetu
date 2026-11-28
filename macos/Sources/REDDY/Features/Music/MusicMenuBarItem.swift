#if os(macOS)
import SwiftUI
import AppKit
import Observation

/// The menu bar item. A click opens a small player: the cover, the song, a progress bar, the transport, like and volume, and a way back to the app. A right click (or
/// Control-click) gives the plain menu. The icon follows the player (a waveform while it plays, a note when it does not), driven by observation of the player, with no timer.
@MainActor
final class MusicMenuBarItem: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private var item: NSStatusItem?
    private weak var hub: MusicHub?
    private let popover = NSPopover()

    func setVisible(_ on: Bool, hub: MusicHub) {
        self.hub = hub
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            i.button?.setAccessibilityLabel("StreamSetu Music")
            i.button?.target = self
            i.button?.action = #selector(clicked(_:))
            i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = i
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: MusicMenuBarPopoverView(hub: hub, close: { [weak self] in self?.popover.performClose(nil) }))
            updateIcon()
            track()
        } else if !on, let i = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    /// Re-reads the icon whenever what it shows changes.
    private func track() {
        guard let hub, item != nil else { return }
        withObservationTracking {
            _ = hub.player.isPlaying
            _ = hub.player.current?.uid
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon(); self?.track() }
        }
    }

    private func updateIcon() {
        guard let button = item?.button, let hub else { return }
        let playing = hub.player.isPlaying
        let img = NSImage(systemSymbolName: playing ? "waveform" : "music.note", accessibilityDescription: playing ? "StreamSetu Music, playing" : "StreamSetu Music")
        img?.isTemplate = true
        button.image = img
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let menu = NSMenu(); menu.delegate = self
            item?.menu = menu
            sender.performClick(nil)
            item?.menu = nil
            return
        }
        if popover.isShown { popover.performClose(sender) }
        else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let hub else { return }
        let p = hub.player
        let locked = hub.room.controlsLocked
        let now = NSMenuItem(title: p.current.map { MusicDesktopRules.windowTitle(for: $0) } ?? "Nothing playing", action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)
        menu.addItem(.separator())
        func add(_ title: String, _ enabled: Bool, _ run: @escaping @MainActor () -> Void) {
            let m = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            let a = MenuAction(run); m.target = a; m.representedObject = a; m.isEnabled = enabled
            menu.addItem(m)
        }
        add(p.isPlaying ? "Pause" : "Play", p.current != nil && !locked) { p.toggle() }
        add("Next", p.current != nil && !locked) { p.next() }
        add("Previous", p.current != nil && !locked) { p.previous() }
        menu.addItem(.separator())
        add("Show StreamSetu", true) { MusicMiniPlayerController.shared.showMainWindow() }
    }

    /// Carries a closure into a menu item.
    private final class MenuAction: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        @MainActor @objc func fire() { run() }
    }
}

/// The popover's content: 320 pt wide, the same ink, accent and type as the app.
struct MusicMenuBarPopoverView: View {
    @Bindable var hub: MusicHub
    var close: () -> Void = {}
    @Environment(\.reddyAccent) private var accent

    private var player: MusicPlayer { hub.player }
    private var locked: Bool { hub.room.controlsLocked }

    var body: some View {
        VStack(spacing: MusicSpace.md) {
            if let t = player.current {
                HStack(spacing: MusicSpace.sm) {
                    MusicBarArtwork(thumbs: t.thumbnails, size: 72, artworkClass: .mini, corner: MusicCorner.card, track: t)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: t.title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(2)
                        Text(verbatim: t.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        if let a = t.album?.title, !a.isEmpty { Text(verbatim: a).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Button { hub.library.toggleLike(t) } label: {
                        Image(systemName: hub.library.isLiked(t) ? "heart.fill" : "heart").font(.system(size: 15)).foregroundStyle(hub.library.isLiked(t) ? accent : ColorTokens.textSecondary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).hoverHighlight(radius: 8).accessibilityLabel(hub.library.isLiked(t) ? "Unlike" : "Like")
                    .atlasCovers("control.music.sharedPartsMusictrackrowbodyButton")
                }
                progress
                transport
                volume
            } else {
                VStack(spacing: MusicSpace.xs) {
                    Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(ColorTokens.textTertiary)
                    Text("Nothing is playing").font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                    Text("Pick something in Music and it shows up here.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, MusicSpace.lg)
            }
            Divider().overlay(ColorTokens.line)
            Button { close(); MusicMiniPlayerController.shared.showMainWindow() } label: {
                HStack { Image(systemName: "arrow.up.forward.app"); Text("Open StreamSetu"); Spacer() }.font(Typography.bodyMedium).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(ColorTokens.textPrimary).hoverHighlight(radius: 8)
            .atlasCovers("control.music.sidebarNowPlaying")
        }
        .padding(MusicSpace.md)
        .frame(width: 320)
        .background(ColorTokens.surface)
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { min(player.position, max(player.duration, 1)) }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                .tint(accent).disabled(locked || player.duration <= 0).controlSize(.small)
                .accessibilityLabel("Position")
            HStack {
                Text(verbatim: Self.clock(player.position)); Spacer(); Text(verbatim: "-" + Self.clock(max(0, player.duration - player.position)))
            }
            .font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: MusicSpace.md) {
            icon(player.shuffle ? "shuffle.circle.fill" : "shuffle", on: player.shuffle, label: "Shuffle") { player.shuffle.toggle() }
            Spacer()
            icon("backward.fill", label: "Previous") { player.previous() }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(ColorTokens.onAccent(accent))
                    .frame(width: 44, height: 44).background(accent, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(locked).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .atlasCovers("control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
            icon("forward.fill", label: "Next") { player.next() }
            Spacer()
            icon(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off, label: "Repeat") {
                player.repeatMode = player.repeatMode == .off ? .all : (player.repeatMode == .all ? .one : .off)
            }
        }
    }

    private var volume: some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).tint(accent).controlSize(.small).accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private func icon(_ symbol: String, on: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(on ? accent : ColorTokens.textPrimary)
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: 8).disabled(locked).accessibilityLabel(label)
        .atlasCovers("control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut")
    }

    static func clock(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
#endif
