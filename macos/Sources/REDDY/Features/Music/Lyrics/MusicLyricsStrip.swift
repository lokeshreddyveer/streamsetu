import SwiftUI

/// The lyrics strip: a slim card just above the player bar showing the line before, the line being sung and the next one, in the style the person picked. It
/// reads the same lyrics, clock and offsets as the side panel's Lyrics tab. Tapping a line jumps to it. Unsynced lyrics have no current line, so it points
/// to the side panel instead.
struct MusicLyricsStrip: View {
    let hub: MusicHub
    let state: MusicContextPanelState
    let close: () -> Void

    @AppStorage(MusicLyricsStripPrefs.styleKey) private var styleRaw = MusicLyricsStripStyle.threeLines.rawValue
    @AppStorage(MusicLyricsStripPrefs.opacityKey) private var opacity = 0.9
    @AppStorage(MusicLyricsPrefs.textStepKey) private var textStep = 1
    /// Read through AppStorage so a change made in the panel toolbar reaches the strip at once, even while the song is paused.
    @AppStorage(MusicLyricsPrefs.alignmentKey) private var alignRaw = 0
    @State private var keeper = MusicLyricsTimeKeeper()
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The lyrics timing the person set in Music settings (milliseconds).
    private var globalOffset: Int { Int(hub.library.settings.lyricsOffsetMs) }
    /// Text colours follow the theme (light or dark, and the palette the person chose); only Cover glow, which sits on a dark scrim over the cover, is always light.
    private var ink: Color { style == .coverGlow ? .white : ColorTokens.textPrimary }
    private var style: MusicLyricsStripStyle { MusicLyricsStripStyle(rawValue: styleRaw) ?? .threeLines }
    private var track: MusicTrack? { hub.player.current }
    private var loadState: MusicLyricsLoadState { track.map { hub.lyrics.loadState(for: $0) } ?? .idle }
    private var lyrics: MusicLyrics? { if case .found(let l) = loadState { return l }; return nil }
    /// Changes when lyrics for the playing song become available.
    /// Changes when the song changes and also when the lyrics change under the same song (another source, an edit): a translation or reading made for other lines must be made again.
    private var foundKey: String? { lyrics.map { l in "\(track?.uid ?? "")|\(l.providerID)|\(l.synced?.count ?? 0)|\(l.plain?.count ?? 0)|\(l.revision ?? 0)" } }
    private var scale: Double { MusicLyricsPrefs.textSteps[min(MusicLyricsPrefs.textSteps.count - 1, max(0, textStep))] }

    @Environment(\.musicTint) private var tint
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    /// Lines that are not the one being sung stay readable (about 4.5:1 on the card); with Increase Contrast they are stronger still.
    private var quiet: Double { contrast == .increased ? 0.8 : 0.62 }
    private var unsung: Double { contrast == .increased ? 0.7 : 0.5 }
    /// Where lines sit: the saved alignment of the side panel (automatic and centre are centred).
    private var hAlign: Alignment { switch MusicLyricsAlignment(rawValue: alignRaw) ?? .automatic { case .start: .leading; case .end: .trailing; default: .center } }
    private var tAlign: TextAlignment { switch MusicLyricsAlignment(rawValue: alignRaw) ?? .automatic { case .start: .leading; case .end: .trailing; default: .center } }

    private var radius: CGFloat { style == .capsule ? 34 : 24 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header
            content.padding(.top, 2)
        }
        .padding(.horizontal, MusicSpace.lg).padding(.top, MusicSpace.sm).padding(.bottom, MusicSpace.md)
        .frame(maxWidth: 680)
        .background { background }
        .overlay(alignment: .bottom) { progress }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [accent.opacity(0.55), ColorTokens.line, accent.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9))
        .shadow(color: accent.opacity(scheme == .dark ? 0.22 : 0.14), radius: 26, y: 8)
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        .padding(.horizontal, MusicSpace.md)
        // The strip asks for a translation too, and a translation on this device needs a view to run it: without this host a strip shown with the side panel closed waited 90 seconds and failed.
        .modifier(MusicLyricsTranslationHost(bridge: hub.translationBridge))
        .task(id: "\(track?.uid ?? "")#\(hub.lyrics.epoch)") { if let t = track { hub.lyrics.ensureLoaded(t) } }
        // A song's lyrics arriving while the reading or translation switch is already on: ask for the extra line then, not only when the switch flips.
        .onChange(of: foundKey, initial: true) { old, key in if key != nil, let t = track, let l = lyrics { if old != nil, old != key { hub.translation.reset() }; MusicLyricsExtrasRequest.request(hub: hub, track: t, lyrics: l) } }
        .onChange(of: hub.lyrics.updateCount) { _, _ in
            guard let t = track else { return }
            let shown = lyrics
            Task { await hub.lyrics.refreshAfterUpdate(for: t, shown: shown, stillCurrent: { track?.uid == t.uid }) }
        }
        .onAppear { feed(discontinuity: true) }
        .onChange(of: track?.uid) { _, _ in keeper.songOffsetMs = 0; feed(discontinuity: true) }   // a new song: the old song's predicted position must not drive its lines
        .onChange(of: hub.player.audioAdvancing) { _, _ in feed(discontinuity: true) }
        .onChange(of: lyrics?.offsetMs) { _, new in keeper.songOffsetMs = new ?? 0; feed(discontinuity: true) }
        .onChange(of: globalOffset) { _, new in keeper.globalOffsetMs = MusicLyricsMotion.clampUIOffset(Int64(new)); feed(discontinuity: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Localized.string("Lyrics"))
    }

    // MARK: pieces

    /// The card is made of the theme's own layers: a material, the theme's card fill, a soft glow of the accent (the palette the person chose, or the cover's colour when
    /// "Adapt colours to artwork" is on) and a light sheen from the top edge. Cover glow swaps the fills for the blurred cover on a scrim.
    @ViewBuilder private var background: some View {
        switch style {
        case .coverGlow:
            ZStack {
                if let t = track { MusicArtwork(t.thumbnails, size: 640, corner: 0).blur(radius: 44).scaleEffect(1.6).saturation(1.35) }
                LinearGradient(colors: [.black.opacity(MusicAccessibilityPrefs.strongOverlays(systemIncreasedContrast: contrast == .increased) ? 0.7 : 0.35), .black.opacity(MusicAccessibilityPrefs.strongOverlays(systemIncreasedContrast: contrast == .increased) ? 0.9 : 0.6)], startPoint: .top, endPoint: .bottom)
            }.opacity(opacity)
        case .subtitle:
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(tint.map { Color($0.background) } ?? ColorTokens.surface).opacity(0.55)
            }.opacity(opacity)
        default:
            ZStack {
                // A thicker material and a stronger fill: the page's own text and pictures behind the card must not show through the lines.
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(tint.map { Color($0.card) } ?? ColorTokens.surface).opacity(0.7)
                RadialGradient(colors: [accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [accent.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 360)
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.07 : 0.28), .clear], startPoint: .top, endPoint: .center)
            }.opacity(opacity)
        }
    }

    /// A hairline along the bottom edge: how far into the song it is.
    private var progress: some View { MusicLyricsStripProgress(player: hub.player, inset: radius, accent: accent) }

    private var header: some View {
        HStack(spacing: MusicSpace.sm) {
            Spacer(minLength: MusicSpace.sm)
            MusicLyricsStripStyleMenu(hub: hub)
            Button { state.showPanel(.lyrics); close() } label: { chip("sidebar.right") }
                .buttonStyle(.plain).musicTooltip("Open in the side panel")
                .accessibilityLabel(Localized.string("Open lyrics in the side panel")).atlas("control.music.lyricsStripPanel")
            Button(action: close) { chip("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Localized.string("Close lyrics")).atlas("control.music.lyricsStripClose")
        }
        .frame(height: 26)
    }

    /// A small round icon button in the theme's own colours.
    private func chip(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.75))
            .frame(width: 26, height: 26).background(Circle().fill(ink.opacity(0.08))).contentShape(Circle())
    }

    @ViewBuilder private var content: some View {
        if track == nil {
            note(Localized.string("Nothing is playing"))
        } else if let l = lyrics, let lines = l.synced, !lines.isEmpty {
            TimelineView(.animation(minimumInterval: 0.15, paused: !hub.player.audioAdvancing)) { ctx in
                // The clock is fed here, once per tick, so the strip itself is not re-drawn by the player's position.
                let ms = fed(ctx.date)
                lines3(lines, ms: ms)
            }
        } else if let l = lyrics, l.plain != nil {
            VStack(spacing: 4) {
                note(Localized.string("These lyrics are not time-synced."))
                Button(Localized.string("Open in the side panel")) { state.showPanel(.lyrics); close() }.buttonStyle(.link).font(Typography.caption).atlas("control.music.lyricsStripPanelLink")
            }
        } else if case .idle = loadState { note("") } else if !loadState.isTerminal { MusicLoadingIcon(size: MusicIconSize.small).frame(height: 56) }
        else if let l = lyrics, l.instrumental { note(Localized.string("Instrumental")) }
        else if case .none(.offline) = loadState, let t = track {
            VStack(spacing: 4) {
                note(Localized.string("The lyrics could not be loaded."))
                Button(Localized.string("Try again")) { hub.lyrics.searchAgain(t) }.buttonStyle(.link).font(Typography.caption).atlas("control.music.lyricsStripRetry")
            }
        }
        else { note(Localized.string("No lyrics for this song.")) }
    }

    private func note(_ s: String) -> some View {
        Text(verbatim: s).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: .infinity, minHeight: 44)
    }

    @ViewBuilder private func lines3(_ lines: [MusicLyricLine], ms: Int64) -> some View {
        let w = MusicLyricsStripLogic.window(lines: lines, atMs: ms)
        VStack(spacing: style == .capsule ? 4 : 7) {
            if style.showsNeighbours { neighbour(lines, w.previous).id("p\(w.previous ?? -1)").transition(lineTransition) }
            current(lines, w, ms: ms).id("c\(w.current ?? -1)").transition(lineTransition)
            if style.showsNeighbours { neighbour(lines, w.next).id("n\(w.next ?? -1)").transition(lineTransition) }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: w)
    }

    private var lineTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private func neighbour(_ lines: [MusicLyricLine], _ i: Int?) -> some View {
        let size = (style == .capsule ? 11.0 : 13.0) * scale
        if let i {
            Button { seek(lines[i]) } label: {
                Text(verbatim: lines[i].text).font(.system(size: size, weight: .medium)).foregroundStyle(ink.opacity(quiet)).lineLimit(1).minimumScaleFactor(0.75).multilineTextAlignment(tAlign).frame(maxWidth: .infinity, alignment: hAlign)
            }.buttonStyle(.plain).atlas("control.music.lyricsStripLine")
        } else { Color.clear.frame(height: size + 4) }
    }

    @ViewBuilder private func current(_ lines: [MusicLyricLine], _ w: MusicLyricsStripWindow, ms: Int64) -> some View {
        let size = (style == .subtitle ? 18.0 : (style == .capsule ? 19.0 : 24.0)) * scale
        if let i = w.current {
            let line = lines[i]
            VStack(spacing: 2) {
                Button { seek(line) } label: {
                    Group {
                        if style == .karaoke {
                            let f = MusicLyricsStripLogic.fill(of: line, nextStartMs: w.next.map { lines[$0].timeMs }, atMs: ms)
                            Text(verbatim: line.text).foregroundColor(ink.opacity(unsung)).lineLimit(1).minimumScaleFactor(0.7)
                                .overlay(alignment: .leading) {
                                    Text(verbatim: line.text).foregroundColor(accent).lineLimit(1).minimumScaleFactor(0.7)
                                        .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * f) } }
                                }
                        } else {
                            Text(verbatim: line.text).foregroundColor(ink)
                        }
                    }
                    .font(.system(size: size, weight: .bold, design: .rounded)).multilineTextAlignment(tAlign).lineLimit(2).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: hAlign)
                }.buttonStyle(.plain).atlas("control.music.lyricsStripLine")
                if let sub = subText(for: line, index: i) {
                    Text(verbatim: sub).font(.system(size: 12 * scale)).foregroundStyle(ink.opacity(0.65)).lineLimit(1)
                }
            }
        } else {
            Text(verbatim: "♪").font(.system(size: size, weight: .bold)).foregroundStyle(ink.opacity(0.6)).frame(maxWidth: .infinity)
        }
    }

    /// The sub-line under the current line, chosen the way the side panel chooses it: the romanisation or translation the translation service holds for this song,
    /// else what the lyrics themselves carry. The same two switches (Settings and the panel's toolbar) decide, so the strip and the panel never disagree.
    private func subText(for line: MusicLyricLine, index: Int) -> String? {
        let s = hub.library.settings
        let service: MusicLyricsSubLines? = {
            if s.showRomanisation, let x = hub.translation.romanization.subLines { return x }
            if s.showTranslation, let x = hub.translation.translation.subLines { return x }
            return nil
        }()
        if let t = service?.display(for: index, original: line.text)?.text, !t.isEmpty { return t }
        return MusicLyricsRow.subText(line: line, showTranslation: s.showTranslation, showRomanisation: s.showRomanisation)
    }

    private func seek(_ line: MusicLyricLine) {
        if hub.room.controlsLocked { return }
        let ms = MusicLyricsMotion.seekTime(lineMs: line.timeMs, songOffset: lyrics?.offsetMs ?? 0, globalOffset: keeper.globalOffsetMs)
        let s = TimeInterval(ms) / 1000
        hub.player.seek(to: s)
        keeper.feed(positionSeconds: s, playing: hub.player.audioAdvancing, rate: hub.player.tempo, discontinuity: true)
    }

    /// Feeds the clock with the player's current reading and returns the lyric time now.
    private func fed(_ date: Date) -> Int64 {
        keeper.feed(positionSeconds: hub.player.position, playing: hub.player.audioAdvancing, rate: hub.player.tempo, discontinuity: false)
        return keeper.lyricMs(at: date)
    }

    private func feed(discontinuity: Bool = false) {
        keeper.songOffsetMs = lyrics?.offsetMs ?? 0
        keeper.globalOffsetMs = MusicLyricsMotion.clampUIOffset(Int64(globalOffset))
        keeper.feed(positionSeconds: hub.player.position, playing: hub.player.audioAdvancing, rate: hub.player.tempo, discontinuity: discontinuity)
    }
}

/// The style chooser of the strip. It is a popover, not a menu: the strip redraws several times a second while a song plays, and a system menu is closed by that (which is why styles
/// could be chosen only while the music was paused). A popover stays open while the view under it updates, and this view has no inputs of its own so the strip never rebuilds it.
struct MusicLyricsStripStyleMenu: View {
    let hub: MusicHub
    @AppStorage(MusicLyricsStripPrefs.styleKey) private var styleRaw = MusicLyricsStripStyle.threeLines.rawValue
    @AppStorage(MusicLyricsStripPrefs.opacityKey) private var opacity = 0.9
    @AppStorage(MusicLyricsPrefs.textStepKey) private var textStep = 1
    @State private var open = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "textformat").font(.system(size: 11, weight: .semibold)).foregroundStyle(ColorTokens.textPrimary.opacity(0.75))
                .frame(width: 26, height: 26).background(Circle().fill(ColorTokens.textPrimary.opacity(0.08))).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.string("Lyrics style")).atlas("control.music.lyricsStripStyle")
        .popover(isPresented: $open, arrowEdge: .top) { content }
    }

    /// The strip has no lyrics tab to ask for the work, so a switch turned on here asks the shared service itself (romanisation is local and instant;
    /// translation only when the song's own lyrics carry none and the person has chosen a language).
    private func requestWork() {
        guard let t = hub.player.current, case .found(let l) = hub.lyrics.loadState(for: t), !l.isEmpty else { return }
        MusicLyricsExtrasRequest.request(hub: hub, track: t, lyrics: l)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("Style")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            VStack(spacing: 2) {
                ForEach(MusicLyricsStripStyle.allCases, id: \.rawValue) { st in
                    Button { styleRaw = st.rawValue } label: {
                        HStack { Text(st.title); Spacer(minLength: 12); if styleRaw == st.rawValue { Image(systemName: "checkmark").foregroundStyle(accent) } }
                            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 6).fill(styleRaw == st.rawValue ? accent.opacity(0.14) : .clear))
                    }.buttonStyle(.plain).atlas("control.music.lyricsStripStyleChoice")
                }
            }
            Divider()
            HStack(spacing: MusicSpace.sm) {
                Text(Localized.string("Text size")).font(Typography.caption)
                Spacer(minLength: 8)
                Button { textStep = max(0, textStep - 1) } label: { Image(systemName: "textformat.size.smaller").frame(width: 28, height: 24) }
                    .buttonStyle(.bordered).disabled(textStep <= 0).accessibilityLabel(Localized.string("Smaller text")).musicTooltip("Smaller text").atlas("control.music.lyricsStripSmaller")
                Button { textStep = min(MusicLyricsPrefs.textSteps.count - 1, textStep + 1) } label: { Image(systemName: "textformat.size.larger").frame(width: 28, height: 24) }
                    .buttonStyle(.bordered).disabled(textStep >= MusicLyricsPrefs.textSteps.count - 1).accessibilityLabel(Localized.string("Larger text")).musicTooltip("Larger text").atlas("control.music.lyricsStripLarger")
            }
            HStack(spacing: MusicSpace.sm) {
                Text(Localized.string("Background")).font(Typography.caption)
                Spacer(minLength: 8)
                Button { opacity = max(0.4, opacity - 0.1) } label: { Image(systemName: "circle.lefthalf.filled").frame(width: 28, height: 24) }
                    .buttonStyle(.bordered).disabled(opacity <= 0.4).accessibilityLabel(Localized.string("More see-through background")).musicTooltip("More see-through background").atlas("control.music.lyricsStripClear")
                Button { opacity = min(1, opacity + 0.1) } label: { Image(systemName: "circle.fill").frame(width: 28, height: 24) }
                    .buttonStyle(.bordered).disabled(opacity >= 1).accessibilityLabel(Localized.string("More solid background")).musicTooltip("More solid background").atlas("control.music.lyricsStripSolid")
            }
            // The same two switches as the side panel's lyrics toolbar and Settings: one setting each, so the strip and the panel always agree.
            Toggle(Localized.string("Show translation"), isOn: Binding(get: { hub.library.settings.showTranslation }, set: { hub.library.settings.showTranslation = $0; if $0 { requestWork() } }))
                .toggleStyle(.switch).atlas("control.music.lyricsStripTranslation")
            Toggle(Localized.string("Show romanisation"), isOn: Binding(get: { hub.library.settings.showRomanisation }, set: { hub.library.settings.showRomanisation = $0; if $0 { requestWork() } }))
                .toggleStyle(.switch).atlas("control.music.lyricsStripRomanisation")
        }
        .padding(MusicSpace.md).frame(width: 260)
    }
}

/// The strip's hairline of progress. It reads the player's position itself, so only this small view is redrawn as the song plays, not the whole card.
struct MusicLyricsStripProgress: View {
    let player: MusicPlayer
    let inset: CGFloat
    let accent: Color

    var body: some View {
        GeometryReader { g in
            let w = max(0, g.size.width - 2 * inset), d = max(1, player.duration)
            Capsule().fill(accent.opacity(0.85)).frame(width: w * min(1, max(0, player.position / d)), height: 2)
                .offset(x: inset).frame(maxWidth: .infinity, alignment: .leading).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 4)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
