import SwiftUI
import Observation

// The Music shell's own state, kept as plain values so the tests can drive it without a window:
// the history Back and Forward walk, the context panel's tabs and per-section memory, the three-region geometry and the saved destination.

// MARK: - History

// MARK: - Context panel

enum MusicContextPanelTab: String, CaseIterable, Codable, Identifiable, Sendable {
    case nowPlaying, queue, lyrics, related, credits, info
    var id: String { rawValue }
    /// The tabs that have a button. Info has none (it only repeated what Now Playing and the song page show); the case stays so a saved choice still decodes.
    static var stripTabs: [MusicContextPanelTab] { allCases.filter { $0 != .info } }

    /// A saved tab this build does not know (written by a newer build, or a removed one) reads as Now Playing, so one unknown value never discards
    /// the panel memory of every section.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .nowPlaying
    }
    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .queue: "Queue"
        case .lyrics: "Lyrics"
        case .related: "Related"
        case .credits: "Credits"
        case .info: "Info"
        }
    }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .queue: "list.bullet"
        case .lyrics: "quote.bubble"
        case .related: "sparkles"
        case .credits: "person.2"
        case .info: "info.circle"
        }
    }
}

/// What the panel remembers for each section: whether it is open and which tab it shows.
struct MusicContextPanelMemory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var isOpen: Bool
        var tab: MusicContextPanelTab
    }
    static let fallback = Entry(isOpen: false, tab: .nowPlaying)
    private(set) var entries: [String: Entry] = [:]

    func entry(for s: MusicSection) -> Entry { entries[s.rawValue] ?? Self.fallback }
    mutating func set(_ e: Entry, for s: MusicSection) { entries[s.rawValue] = e }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> MusicContextPanelMemory {
        guard let data, let m = try? JSONDecoder().decode(MusicContextPanelMemory.self, from: data) else { return MusicContextPanelMemory() }
        return m
    }
}

/// The context panel's state. One instance serves the shell; the player bar opens a tab through it (`show`, `toggle`). The state is remembered per
/// section, so Home can keep Lyrics open while Library keeps the panel closed.
@MainActor @Observable
final class MusicContextPanelState {
    static let shared = MusicContextPanelState()

    private(set) var section: MusicSection = .home
    private(set) var memory: MusicContextPanelMemory
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        memory = MusicContextPanelMemory.decode(defaults.data(forKey: MusicShellKeys.contextPanels))
    }

    /// True only once the person has opened the panel during this visit to the page. Arriving on a page never opens it, whatever that page remembered: the page keeps its
    /// choice of tab, not a decision to open.
    private var openedHere = false
    var isOpen: Bool { openedHere && memory.entry(for: section).isOpen }
    /// The tab the panel shows. The panel's own Lyrics tab shows the lyrics inside the side panel, with no sheet.
    /// A panel last left on the retired Info tab opens on Related, so the strip always highlights a tab that exists.
    var selectedTab: MusicContextPanelTab { let t = memory.entry(for: section).tab; return t == .info ? .related : t }

    /// Whether the lyrics strip (a slim card just above the player bar, showing the line before, the current line and the next one) is open. Every lyrics button
    /// outside the side panel (the player bar, "View lyrics" in a menu) opens it and leaves the panel alone; it is not remembered across launches.
    var lyricsStripOpen = false

    /// The shell calls this when the section changes; the panel takes that section's remembered state.
    func enter(_ s: MusicSection) {
        if s != section { overlayArmed = false; openedHere = false }
        section = s
    }

    /// True only after the person opened the panel themselves (button, shortcut, Now Playing card) and until the section or window class changes.
    /// A remembered "open" never pops the panel up over the page as an overlay: only the inline panel of a wide window is restored.
    private(set) var overlayArmed = false
    func disarmOverlay() { overlayArmed = false }

    func show(_ tab: MusicContextPanelTab) {
        // A listening mode that hides the strip (study) would leave it "open" yet invisible: the lyrics then open in the side panel instead.
        if tab == .lyrics, !MusicListeningModes.profile.hidesLyricsStrip { lyricsStripOpen = true; return }
        overlayArmed = true; update(isOpen: true, tab: tab)
    }
    /// The panel's own tab row: its Lyrics tab shows the lyrics inside the panel (no strip, no sheet).
    func select(_ tab: MusicContextPanelTab) {
        update(isOpen: isOpen, tab: tab)
    }
    /// Closes the lyrics strip when it is open (the button that opened it closes it too), otherwise the side panel.
    func close() {
        if lyricsStripOpen { lyricsStripOpen = false; return }
        update(isOpen: false, tab: selectedTab)
    }
    /// Open on `tab`; pressed again on the tab that is showing, it closes. Lyrics from a button outside the panel is the strip.
    func toggle(_ tab: MusicContextPanelTab) {
        if tab == .lyrics, !MusicListeningModes.profile.hidesLyricsStrip { lyricsStripOpen.toggle(); return }
        if isOpen && selectedTab == tab { close() } else { show(tab) }
    }
    /// Closes the side panel only (the panel's own X and Escape). The lyrics strip is a separate surface and keeps its own button.
    /// Opens the panel on `tab`, Lyrics included (a spoken or typed request for the lyrics panel is an explicit action).
    func showPanel(_ tab: MusicContextPanelTab) { overlayArmed = true; update(isOpen: true, tab: tab) }
    func closePanel() { update(isOpen: false, tab: selectedTab) }
    /// The toggle works on what the person SEES: `shown` is whether the panel is on screen now. A panel that is open but hidden (a wide window shrunk to a narrow one)
    /// opens on the first press instead of needing two.
    func toggleOpen(shown: Bool? = nil) {
        if shown ?? isOpen { closePanel(); overlayArmed = false } else { overlayArmed = true; update(isOpen: true, tab: selectedTab) }
    }

    private func update(isOpen: Bool, tab: MusicContextPanelTab) {
        if isOpen { openedHere = true }
        var next = memory
        next.set(.init(isOpen: isOpen, tab: tab), for: section)
        guard next != memory else { return }
        memory = next
        if let data = memory.encoded() { defaults.set(data, forKey: MusicShellKeys.contextPanels) }
    }

    /// For the existing player bar, which still talks about the three older panels.
    var legacyPanel: MusicPanel? {
        if lyricsStripOpen { return .lyrics }
        guard isOpen else { return nil }
        switch selectedTab {
        case .nowPlaying: return .nowPlaying
        case .queue: return .queue
        case .lyrics: return .lyrics
        case .related, .credits, .info: return nil
        }
    }

    func setLegacy(_ p: MusicPanel?) {
        guard let p else { close(); return }
        switch p {
        case .nowPlaying: lyricsStripOpen = false; show(.nowPlaying)
        case .queue: lyricsStripOpen = false; show(.queue)
        case .lyrics: show(.lyrics)
        }
    }
}

// MARK: - Geometry

/// Whether the context panel is drawn: inline panels follow the remembered state; an overlay needs the person's own request this time.
enum MusicPanelPresentation {
    static func shown(isOpen: Bool, hasTrack: Bool, inline: Bool, overlayArmed: Bool) -> Bool {
        isOpen && hasTrack && (inline || overlayArmed)
    }

    /// The floating side-panel button is drawn only while a song is loaded and the panel is closed: an open panel has its own close button, so a second icon beside it would
    /// be a duplicate.
    static func showsToggleButton(hasTrack: Bool, panelShown: Bool) -> Bool { hasTrack && !panelShown }
}

/// The three regions for the width Music is given: navigation (A), content (B) and the context panel (C).
struct MusicShellGeometry: Equatable, Sendable {
    var shellClass: MusicLayoutClass
    var navExpanded: Bool
    var navWidth: CGFloat
    var panelOpen: Bool
    var panelInline: Bool
    var panelWidth: CGFloat
    /// What is left for the page, and its class (what screens should use for margins and columns).
    var contentWidth: CGFloat
    var contentClass: MusicLayoutClass

    /// `totalWidth` is the width the Music content area is given (not the window). `sidebarExpanded` is the person's choice; below 1000 pt the
    /// sidebar is compact whatever it says.
    static func resolve(totalWidth: CGFloat, sidebarExpanded: Bool, panelOpen: Bool, userPanelWidth: CGFloat? = nil) -> MusicShellGeometry {
        let cls = MusicLayoutClass.resolve(width: totalWidth)
        let inline = panelOpen && MusicLayoutGrid.contextPanelInline(for: cls)
        // The three regions share the width: the panel scales with the window, the sidebar keeps its labels only while the page keeps a comfortable width, the page gets the rest.
        // A width the person dragged the panel to wins (kept between 280 and 500, and leaving the page its room); otherwise it scales with the window.
        let panelWidth = userPanelWidth.map { MusicPanelWidth.clamped($0, total: totalWidth) } ?? MusicLayoutGrid.contextPanelWidth(total: totalWidth)
        let nav = MusicLayoutGrid.navWidth(for: cls, expanded: sidebarExpanded, total: totalWidth, panel: inline ? panelWidth : 0)
        let safeTotal = totalWidth.isFinite ? max(0, totalWidth) : 0
        let content = max(0, safeTotal - nav - (inline ? panelWidth : 0))
        return MusicShellGeometry(shellClass: cls, navExpanded: nav > MusicLayoutGrid.navCompactWidth, navWidth: nav, panelOpen: panelOpen,
                                  panelInline: inline, panelWidth: panelWidth, contentWidth: content, contentClass: MusicLayoutClass.resolve(width: content))
    }
}

private struct MusicLayoutClassKey: EnvironmentKey { static let defaultValue = MusicLayoutClass.expanded }

extension EnvironmentValues {
    /// The layout class of the width the page itself is given (after the sidebar and an inline context panel). Screens read this for margins and columns.
    var musicLayoutClass: MusicLayoutClass {
        get { self[MusicLayoutClassKey.self] }
        set { self[MusicLayoutClassKey.self] = newValue }
    }
}

// MARK: - Saved state

/// The switch that turns the connected-universe pages on (off by default; the original pages stay until each screen package lands).
enum MusicGraphKeys {
    static let pages = "music.graph.pages"
    /// The connected song, album and artist pages are ON unless the person switched them off. An unset key means on; `bool(forKey:)` alone reads it as off.
    static var pagesOn: Bool { (UserDefaults.standard.object(forKey: pages) as? Bool) ?? true }
}

/// The `music.shell.*` UserDefaults keys. Each one is listed in `MusicDefaultsKeys`.
enum MusicShellKeys {
    static let destination = "music.shell.destination"
    static let sidebarExpanded = "music.shell.sidebarExpanded"
    static let sidebarAutoHide = "music.shell.sidebarAutoHide"
    static let contextPanels = "music.shell.contextPanels"
    static let scroll = "music.shell.scroll"
    static let searchQuery = "music.shell.searchQuery"
    static let barHidden = "music.shell.barHidden"
    static let session = "music.shell.session"
    /// The side panel's width in points; absent means the default. Kept next to `contextPanels`.
    static let panelWidth = "music.shell.panelWidth"
    /// The seek bar's right-hand time: false shows the time left, true the song's whole length.
    static let showTotalTime = "music.player.showTotalTime"
    /// The Now Playing panel's layout mode (compact, balanced or immersive).
    static let nowPlayingMode = "music.nowPlaying.mode"
}

/// Reads and writes the saved destination, sidebar choice, scroll positions and search words. Device-local; the search words are activity and go with
/// `MusicHub.wipeAll`.
struct MusicShellStore {
    var defaults: UserDefaults = .standard
    static let scrollLimit = 24

    /// The section the person was on. Settings is a sheet, so it is never the place to come back to.
    var destination: MusicSection? {
        get { defaults.string(forKey: MusicShellKeys.destination).flatMap(MusicSection.init(rawValue:)).flatMap { $0 == .settings ? nil : $0 } }
        nonmutating set {
            if let newValue, newValue != .settings { defaults.set(newValue.rawValue, forKey: MusicShellKeys.destination) }
        }
    }

    /// The last session's places (ids and page memory only), so a relaunch can return to the page the person was on. Device-local and small; it
    /// records what was visited, so `MusicHub.wipeAll` removes it.
    var session: MusicSessionSnapshot? {
        get { defaults.data(forKey: MusicShellKeys.session).flatMap { try? JSONDecoder().decode(MusicSessionSnapshot.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue), data.count <= 64 * 1024 { defaults.set(data, forKey: MusicShellKeys.session) }
            else { defaults.removeObject(forKey: MusicShellKeys.session) }
        }
    }

    var sidebarExpanded: Bool {
        get { defaults.object(forKey: MusicShellKeys.sidebarExpanded) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: MusicShellKeys.sidebarExpanded) }
    }

    /// The sidebar rests as the icon rail and opens over the page while the pointer is on it. On unless the person pinned the sidebar open.
    var sidebarAutoHide: Bool {
        get { defaults.object(forKey: MusicShellKeys.sidebarAutoHide) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: MusicShellKeys.sidebarAutoHide) }
    }

    var searchQuery: String {
        get { String((defaults.string(forKey: MusicShellKeys.searchQuery) ?? "").prefix(200)) }
        nonmutating set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { defaults.removeObject(forKey: MusicShellKeys.searchQuery) } else { defaults.set(String(t.prefix(200)), forKey: MusicShellKeys.searchQuery) }
        }
    }

    var scroll: [String: Double] {
        get {
            guard let raw = defaults.dictionary(forKey: MusicShellKeys.scroll) else { return [:] }
            var out: [String: Double] = [:]
            for (k, v) in raw { if let d = v as? Double, d.isFinite, d >= 0 { out[k] = d } }
            return out
        }
        nonmutating set { defaults.set(newValue, forKey: MusicShellKeys.scroll) }
    }

    /// Keeps the offsets of the newest `scrollLimit` keys (`keys` is oldest first).
    static func trimmed(_ offsets: [String: Double], keys: [String]) -> [String: Double] {
        var seen = Set<String>(), keep: [String] = []
        for k in keys.reversed() where offsets[k] != nil && seen.insert(k).inserted { keep.append(k); if keep.count == scrollLimit { break } }
        return keep.reduce(into: [:]) { $0[$1] = offsets[$1] }
    }
}

// MARK: - Section helpers

enum MusicSectionGroup: Sendable { case primary, more }

extension MusicSection {
    /// The six places in the main list; everything else sits in the quiet "More" group. Nothing is removed.
    var group: MusicSectionGroup {
        switch self {
        case .home, .explore, .recentlyAdded, .search, .library, .radio: .primary
        case .downloads, .devices, .room, .settings: .more
        }
    }

    static var primarySections: [MusicSection] { allCases.filter { $0.group == .primary } }
    static var moreSections: [MusicSection] { allCases.filter { $0.group == .more } }

    /// The word used in `streamsetu://music/open/<section>`.
    var linkName: String {
        switch self {
        case .home: "listen-now"
        case .explore: "explore"
        case .recentlyAdded: "recently-added"
        case .search: "search"
        case .library: "library"
        case .radio: "radio"
        case .downloads: "downloads"
        case .devices: "devices"
        case .room: "listen-together"
        case .settings: "settings"
        }
    }

    /// A section from its link word (also the raw name, so `home` works).
    static func from(linkName name: String) -> MusicSection? {
        let n = name.lowercased()
        return allCases.first { $0.linkName == n || $0.rawValue == n } ?? (n == "listen" || n == "listennow" ? .home : nil)
    }
}

// MARK: - Player bar visibility

/// How the shell shows the player bar: the full bar, a thin progress line (the Now Playing tab is open inline, so the bar would repeat it), or nothing.
enum MusicBarPresentation: Equatable, Sendable { case full, line, hidden }

enum MusicBarVisibility {
    static let lineHeight: CGFloat = MusicSpace.xxs - 1

    static func presentation(hasTrack: Bool, hidden: Bool, panelOpen: Bool, tab: MusicContextPanelTab, panelInline: Bool) -> MusicBarPresentation {
        guard hasTrack, !hidden else { return .hidden }
        return panelOpen && panelInline && tab == .nowPlaying ? .line : .full
    }

    /// The sidebar card and the restore pill exist only while a track is loaded and the bar is hidden, so there is never a third copy.
    static func showsRestoreAffordances(hasTrack: Bool, hidden: Bool) -> Bool { hasTrack && hidden }
}

/// Hide and restore as a small state machine. Hiding never touches playback; a song the person starts, or stopping, brings the bar back.
struct MusicBarHideState: Equatable, Sendable {
    var hidden = false
    mutating func hide() { hidden = true }
    mutating func restore() { hidden = false }
    mutating func trackStartedByPerson() { hidden = false }
    mutating func stopped() { hidden = false }
}

/// The hidden flag, kept per device.
@MainActor @Observable
final class MusicBarVisibilityModel {
    static let shared = MusicBarVisibilityModel()
    private(set) var state: MusicBarHideState
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = MusicBarHideState(hidden: defaults.bool(forKey: MusicShellKeys.barHidden))
    }

    var hidden: Bool { state.hidden }
    func hide() { apply { $0.hide() } }
    func restore() { apply { $0.restore() } }
    func stopped() { apply { $0.stopped() } }

    private func apply(_ f: (inout MusicBarHideState) -> Void) {
        var next = state
        f(&next)
        guard next != state else { return }
        state = next
        if next.hidden { defaults.set(true, forKey: MusicShellKeys.barHidden) } else { defaults.removeObject(forKey: MusicShellKeys.barHidden) }
    }
}

// MARK: - The player bar slot

/// The shell mounts the player bar here, once, with the layout class of the width the shell was given.
struct MusicShellPlayerBarSlot: View {
    let hub: MusicHub
    let layout: MusicLayoutClass
    var panelState: MusicContextPanelState = .shared
    /// Whether the context panel sits beside the page (wide layout) rather than over it.
    var panelInline = false
    @State private var visibility = MusicBarVisibilityModel.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let hasTrack = hub.player.current != nil
        let mode = MusicBarVisibility.presentation(hasTrack: hasTrack, hidden: visibility.hidden, panelOpen: panelState.isOpen,
                                                   tab: panelState.selectedTab, panelInline: panelInline)
        let reduce = BrandMotion.reduced(systemReduceMotion)
        Group {
            switch mode {
            case .full:
                let panel = Binding<MusicPanel?>(get: { panelState.legacyPanel }, set: { panelState.setLegacy($0) })
                MusicPlayerBar(hub: hub, layout: layout, panel: panel).transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            case .line:
                MusicBarThinLine(player: hub.player).transition(.opacity)
            case .hidden:
                if MusicBarVisibility.showsRestoreAffordances(hasTrack: hasTrack, hidden: visibility.hidden) { restorePill }
            }
        }
        .animation(MusicMotion.animation(.panel, reduce: reduce), value: mode)
        // The full-window player is an overlay above this slot: the bar underneath must not stay clickable or readable by VoiceOver.
        .allowsHitTesting(!hub.expandedPlayer)
        .accessibilityHidden(hub.expandedPlayer)
        .onChange(of: mode, initial: true) { _, m in
            MusicChromeState.shared.barInset = Self.inset(m, restorePill: MusicBarVisibility.showsRestoreAffordances(hasTrack: hub.player.current != nil, hidden: visibility.hidden))
        }
    }

    /// The height the bar takes at the bottom for each way of showing it: the full bar, the thin line, or the small restore pill (or nothing).
    static func inset(_ m: MusicBarPresentation, restorePill: Bool = false) -> CGFloat {
        switch m {
        case .full: MusicBarMetrics.heightFull
        case .line: MusicBarVisibility.lineHeight
        case .hidden: restorePill ? MusicTokens.hitTarget + MusicSpace.md : 0
        }
    }

    /// A stable spot: the bottom-right corner of the content, above where the bar was.
    private var restorePill: some View {
        Color.clear.frame(height: 0).overlay(alignment: .bottomTrailing) {
            Button { visibility.restore() } label: {
                HStack(spacing: MusicSpace.xs) {
                    Image(systemName: "chevron.up").font(MusicTokens.iconSmall)
                    Text("Show player").font(Typography.caption)
                }
                .foregroundStyle(ColorTokens.textPrimary)
                .padding(.horizontal, MusicSpace.sm).frame(minHeight: MusicTokens.hitTarget)
                .background(ColorTokens.surface, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.lineStrong))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).padding(MusicSpace.sm)
            .accessibilityLabel("Show player").musicTooltip("Show player")
            .atlas("control.music.playerRestore")
        }
    }
}
