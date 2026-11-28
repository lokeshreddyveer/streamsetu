import SwiftUI

// Music settings. A quiet list of six tabs on the left, the app's own settings groups and rows on the right. Each source, sign-in and
// plugin needs the person's own action to change; what a source is sent is in its Details popover.

enum MusicQualityText {
    static func title(_ q: MusicQuality) -> String {
        switch q { case .low: "Low (data saver)"; case .medium: "Medium"; case .high: "High"; case .lossless: "Lossless when available" }
    }
    static let all: [MusicQuality] = [.low, .medium, .high, .lossless]
}

/// The settings sheet's size: it opens at the ideal size and can be resized between the minimum and maximum; inline it fills the page.
private struct SettingsFrame: ViewModifier {
    let inSheet: Bool
    func body(content: Content) -> some View {
        if inSheet {
            content.frame(minWidth: MusicSettingsLayout.minWidth, idealWidth: MusicSettingsLayout.idealWidth, maxWidth: MusicSettingsLayout.maxWidth,
                          minHeight: MusicSettingsLayout.minHeight, idealHeight: MusicSettingsLayout.idealHeight, maxHeight: MusicSettingsLayout.maxHeight)
        } else { content }
    }
}

/// The Music settings: a left list of tabs with a search field, and the chosen tab's groups. Used inline as a page and inside a sheet.
struct MusicSettingsPage: View {
    let hub: MusicHub
    var route = MusicSettingsRoute()
    var onClose: (() -> Void)?

    @State private var tab: MusicSettingsTab = .general
    @State private var query = ""
    @State private var flash: String?
    @State private var scrollTarget: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: MusicSettings { hub.library.settings }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        GeometryReader { geo in
            let mode = MusicSettingsLayout.rail(forWidth: geo.size.width)
            let region = MusicSettingsLayout.regionWidth(total: geo.size.width)
            HStack(spacing: 0) {
                rail(mode)
                Rectangle().fill(ColorTokens.line).frame(width: 1)
                VStack(spacing: 0) {
                    if mode == .icons { compactHeader }
                    Group { if searching { results(region: region) } else { tabContent(region: region) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(SettingsFrame(inSheet: onClose != nil))
        .onAppear { tab = route.tab; query = ""; if let a = route.anchor { flashBlock(a) } }
        .onChange(of: route) { _, r in tab = r.tab; query = ""; if let a = r.anchor { flashBlock(a) } }
    }

    // MARK: shell

    private var closeButton: some View {
        Button(action: { onClose?() }) { Image(systemName: "xmark").accessibilityHidden(true) }
            .musicButton(.icon, size: .compact).keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close settings").help("Close").atlas("control.music.settingsCloseSettings")
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            TextField("Search settings", text: $query).textFieldStyle(.plain).musicScaledText(.body).focused($searchFocused)
                .onSubmit { if let first = MusicSettingsSearch.search(query, in: MusicSettingsSearch.index).first?.entries.first { open(first) } }
                .accessibilityLabel("Search settings").atlas("control.music.settingsSearch")
            #if os(macOS)
                .onExitCommand { query = "" }
            #endif
            if searching {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityHidden(true) }
                    .musicButton(.icon, size: .compact).accessibilityLabel("Clear search").help("Clear search").atlas("control.music.settingsClearSearch")
            }
        }
        .padding(.horizontal, Spacing.sm).frame(minHeight: MusicSettingsLayout.rowHeight)
        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous))
        .musicContrastBorder(cornerRadius: MusicTokens.radiusRow, always: false)
    }

    /// Below the collapse width the rail is icons only, so the title, search and close move above the page.
    private var compactHeader: some View {
        HStack(spacing: Spacing.sm) {
            Text("Settings").musicScaledText(.section).lineLimit(1).accessibilityAddTraits(.isHeader)
            searchField.frame(maxWidth: .infinity)
            if onClose != nil { closeButton }
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
    }

    private func rail(_ mode: MusicSettingsLayout.Rail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if mode == .full {
                HStack {
                    Text("Settings").musicScaledText(.section).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if onClose != nil { closeButton }
                }
                searchField
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.xxs) { ForEach(MusicSettingsTab.allCases) { railRow($0, mode: mode) } }
            }
            Spacer(minLength: 0)
        }
        .padding(mode == .full ? Spacing.md : Spacing.xs).padding(.top, mode == .icons ? Spacing.xs : 0)
        .frame(width: MusicSettingsLayout.railWidth(mode)).frame(maxHeight: .infinity)
        .background(ColorTokens.sidebar.opacity(0.5))
        .accessibilityElement(children: .contain)
    }

    private func railRow(_ t: MusicSettingsTab, mode: MusicSettingsLayout.Rail) -> some View {
        let on = tab == t && !searching
        return Button { tab = t; query = "" } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: t.symbol).font(MusicTokens.iconMedium).foregroundStyle(on ? accent : ColorTokens.textSecondary).frame(width: Spacing.xl)
                if mode == .full {
                    Text(LocalizedStringKey(t.title)).font(on ? Typography.bodyMedium : Typography.body).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: MusicSettingsLayout.railRowHeight, alignment: mode == .full ? .leading : .center)
        }
        .buttonStyle(MusicRailRowStyle(selected: on)).focusEffectDisabled()
        .help(Text(LocalizedStringKey(t.title)))
        .accessibilityLabel(LocalizedStringKey(t.title)).accessibilityAddTraits(on ? .isSelected : []).atlas("control.music.settingsMusicsettingspagerailrowButton")
    }

    static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "v" + $0 } ?? ""
    }

    // MARK: search

    private func results(region: CGFloat) -> some View {
        let groups = MusicSettingsSearch.search(query, in: MusicSettingsSearch.index)
        return settingsScroll(region: region) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if groups.isEmpty { Text(verbatim: Localized.string("Nothing matches \"%@\".", query)).musicScaledText(.card) }
                ForEach(groups, id: \.tab) { g in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(LocalizedStringKey(g.tab.title)).musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary).accessibilityAddTraits(.isHeader)
                        ForEach(g.entries) { e in resultRow(e) }
                    }
                }
            }
        }
    }

    private func resultRow(_ e: MusicSettingsEntry) -> some View {
        Button { open(e) } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(highlighted(Localized.string(e.title))).font(Typography.body)
                if !e.section.isEmpty { Text(LocalizedStringKey(e.section)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            }
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().accessibilityLabel(Text(verbatim: Localized.string(e.title))).atlas("control.music.settingsMusicsettingspageresultrowButton")
    }

    private func highlighted(_ title: String) -> AttributedString {
        var out = AttributedString(title)
        for t in MusicSettingsSearch.terms(query) {
            if let r = out.range(of: t, options: .caseInsensitive) { out[r].backgroundColor = accent.opacity(MusicTokens.flashFill) }
        }
        return out
    }

    private func open(_ e: MusicSettingsEntry) { openBlock(e.tab, e.anchor) }

    private func openBlock(_ t: MusicSettingsTab, _ anchor: String) {
        tab = t; query = ""
        flashBlock(anchor)
    }

    private func flashBlock(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)       // the tab has to render before it can be scrolled
            scrollTarget = id
            flash = id
            try? await Task.sleep(nanoseconds: UInt64(MusicTokens.flashSeconds * MusicTokens.flashHold * 1_000_000_000))
            if reduceMotion { flash = nil } else { withAnimation(.easeOut(duration: MusicTokens.flashSeconds * (1 - MusicTokens.flashHold))) { flash = nil } }
        }
    }

    // MARK: tab content

    /// The one scroll area of the page: side margin and column cap from the shared grid, a top inset, and a bottom inset so the last row and any footer clear the window edge.
    private func settingsScroll<C: View>(region: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicSettingsLayout.groupSpacing) { content() }
                .frame(maxWidth: MusicSettingsLayout.maxWidth, alignment: .leading)
                .padding(.horizontal, MusicSettingsLayout.margin(forRegion: region))
                .padding(.top, MusicSettingsLayout.topInset).padding(.bottom, MusicSettingsLayout.footerInset())
                .frame(maxWidth: .infinity)
        }
    }

    private func tabContent(region: CGFloat) -> some View {
        ScrollViewReader { proxy in
            settingsScroll(region: region) { paneHeader; blocks }
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    if reduceMotion { proxy.scrollTo(id, anchor: .center) } else { withAnimation(MusicTokens.standard) { proxy.scrollTo(id, anchor: .center) } }
                    scrollTarget = nil
                }
        }
    }

    /// One block of a tab: one or more groups. It carries its anchor for scrolling and the flash from the search.
    private func block<C: View>(_ id: String, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous).fill(flash == id ? accent.opacity(MusicTokens.flashFill) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous).strokeBorder(flash == id ? accent : Color.clear, lineWidth: 1))
            .id(id)
    }

    /// The pane's title and a line about it, above its cards.
    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text(tab.title.loc).font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
            Text(tab.blurb.loc).musicScaledText(.secondary).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var blocks: some View {
        switch tab {
        case .general:
            block("general.appearance") { MusicThemeSettingsSection(hub: hub) }
            block("general.accessibility") { MusicAccessibilitySettingsGroup() }
        case .playback:
            block("playback.quality") { audioGroup }
            block("playback.player") { MusicPlayerSettingsSection(hub: hub) }
            block("playback.display") { displayGroup }
            block("playback.karaoke") { MusicKaraokeSettingsSection(hub: hub) }
            block("playback.automix") { MusicAutomixSettingsSection(hub: hub) }
            block("playback.output") { MusicOutputDeviceSettingsSection(hub: hub) }
            block("playback.motion") { MusicMotionSettingsSection(hub: hub) }
            block("playback.catalog") { MusicCatalogSettingsSection(hub: hub) }
        case .lyrics:
            block("lyrics.options") { MusicLyricsSettingsSection(hub: hub) }
        case .plugins:
            block("plugins.roles") { MusicRolesSettingsSection(hub: hub, open: openBlock) }
            block("plugins.installed") { MusicInstalledSettingsSection(hub: hub, onRunSetup: { hub.library.settings.consentDone = false; onClose?() }) }
            block("plugins.addons") { MusicSourcesSettingsSection(hub: hub) }
            block("plugins.ownserver") { MusicOwnInstanceSettingsSection(hub: hub) }
            block("plugins.subsonic") { MusicSubsonicSettingsSection(hub: hub) }
            block("plugins.metadata") { MusicMetadataSettingsSection(hub: hub) }
            block("plugins.updates") { MusicExtrasSettingsSection(hub: hub, part: .updates) }
            block("plugins.accounts") { MusicAccountSettingsSection(hub: hub) }
            block("plugins.scrobbling") { MusicScrobbleSettingsSection(hub: hub) }
        case .data:
            block("data.cache") { MusicPlaybackSettingsSection(hub: hub) }
            block("data.local") { MusicExtrasSettingsSection(hub: hub) }
            block("data.backup") { MusicBackupSettingsGroup(hub: hub) }
        case .devices:
            block("devices.rooms") { devicesGroup }
        case .privacy:
            block("privacy.taste") { MusicTasteGroup(hub: hub) }
            block("privacy.data") { MusicDataPrivacyGroup(hub: hub) }
            block("privacy.changes") { MusicSourceChangesGroup(hub: hub) }
            block("privacy.problems") { MusicPlaybackProblemsSection(); MusicPerformanceSection() }
            block("privacy.about") { MusicAboutGroup() }
        }
    }

    // MARK: groups

    private func binding<V>(_ kp: WritableKeyPath<MusicSettings, V>) -> Binding<V> {
        Binding(get: { hub.library.settings[keyPath: kp] }, set: { hub.library.settings[keyPath: kp] = $0 })
    }

    private var audioGroup: some View {
        MusicSettingsGroup(title: "Audio") {
            MusicPickerRow(title: "Audio quality", selection: binding(\.audioQuality), options: MusicQualityText.all.map { ($0, MusicQualityText.title($0)) })
            MusicToggleRow(title: "Skip non-music parts", info: "Skips intros, sponsor reads and silence in YouTube tracks. A community service is asked which parts to skip, using only a short hash of the video id.",
                           isOn: binding(\.skipNonMusicSegments))
            MusicToggleRow(title: "Write song details into downloads", info: "Saves the title, artist, album and cover art inside each download.", isOn: binding(\.tagDownloads))
            MusicButtonRow(title: "Never Play List", button: "Open") { hub.open(.blacklist); onClose?() }
            MusicButtonRow(title: "Hidden Recommendations", atlas: "control.music.settingsHiddenRecommendations", detail: hiddenDetail,
                           info: "Songs and artists you chose to hide from Home, Radio and autoplay. They still play when you pick them.", button: "Clear",
                           disabled: MusicHiddenRecommendations.shared.set.isEmpty) { MusicHiddenRecommendations.shared.clear() }
        }
    }

    private var hiddenDetail: String {
        let h = MusicHiddenRecommendations.shared.set
        return h.isEmpty ? Localized.string("Nothing hidden") : [h.tracks.isEmpty ? nil : Localized.plural(h.tracks.count, one: "%@ song hidden", other: "%@ songs hidden"), h.artists.isEmpty ? nil : Localized.plural(h.artists.count, one: "%@ artist hidden", other: "%@ artists hidden")].compactMap { $0 }.joined(separator: " · ")
    }

    /// The seek bar's look and the optional music videos.
    private var displayGroup: some View {
        MusicSettingsGroup(title: "Player look") {
            MusicArtworkCacheRow()
            MusicToggleRow(title: "Wavy seek bar", info: "Draws the seek bar as a gentle wave that moves while a song plays. Off draws a plain line.",
                           isOn: Binding(get: { settings.player.wavySeekBar }, set: { hub.library.settings.player.wavySeekBar = $0 }))
            MusicToggleRow(title: "Show music videos", info: "When a song has a music video, the full-window player shows the picture with the sound. Songs without a video look the same.",
                           isOn: Binding(get: { settings.player.videoMode }, set: { hub.library.settings.player.videoMode = $0 }))
        }
    }

    private var devicesGroup: some View {
        MusicSettingsGroup(title: "Devices and rooms", footer: "Control Music from a phone, or listen together with friends. Both are off until you start them.") {
            MusicButtonRow(title: "Devices", button: "Open") { hub.nav.select(.devices); onClose?() }
            MusicButtonRow(title: "Listen together", button: "Open") { hub.nav.select(.room); onClose?() }
        }
    }
}
