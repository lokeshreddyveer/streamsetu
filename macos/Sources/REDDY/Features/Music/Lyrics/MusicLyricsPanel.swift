import SwiftUI
#if canImport(Translation)
import Translation
#endif

// The lyrics panel: loads the lyrics for the playing track, shows the animated view (or plain text, instrumental, none found), and carries the
// source picker and the toolbar underneath. Used docked in Now Playing and, with a light ink, in the full-window player.

struct MusicLyricsPanel: View {
    let hub: MusicHub
    var style: MusicLyricsView.Style = .panel
    var ink: Color = ColorTokens.textPrimary
    /// Bumped by the host's toolbar button to open the lyrics editor.
    var editRequest = 0
    /// The page margin around the whole panel (body, empty states and footer). Hosts that already pad their content leave it at 0.
    var inset: CGFloat = 0

    @State private var shareIndices: [Int]?
    @State private var editing = false
    @State private var pickRequest = 0
    @State private var findRequest = 0
    @AppStorage(MusicLyricsPrefs.translationLanguageKey) private var language = ""

    /// The hub's one translation service, shared with the toolbar and the settings.
    private var translation: MusicLyricsTranslationService { hub.translation }

    private var track: MusicTrack? { hub.player.current }
    /// The state lives on the hub's lyrics service (keyed by track), the view only shows it.
    private var loadState: MusicLyricsLoadState { track.map { hub.lyrics.loadState(for: $0) } ?? .idle }
    private var loading: Bool { track != nil && !loadState.isTerminal }
    private var lyrics: MusicLyrics? { if case .found(let l) = loadState { return l }; return nil }
    /// Changes when lyrics for the playing song become available.
    /// Changes when the song changes and also when the lyrics change under the same song (another source, an edit): a translation or reading made for other lines must be made again.
    private var foundKey: String? { lyrics.map { l in "\(track?.uid ?? "")|\(l.providerID)|\(l.synced?.count ?? 0)|\(l.plain?.count ?? 0)|\(l.revision ?? 0)" } }
    private func setLyrics(_ l: MusicLyrics?) { if let t = track { hub.lyrics.adopt(l, for: t) } }
    private var settings: MusicSettings { hub.library.settings }
    private var languageName: String {
        let code = MusicLyricsPrefs.effectiveTranslationLanguage(language)
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    var body: some View {
        VStack(spacing: 10) {
            main
            if let t = track { footer(t) }
        }
        .padding(.horizontal, inset)
        .modifier(MusicLyricsTranslationHost(bridge: hub.translationBridge))
        .task(id: "\(track?.uid ?? "")#\(hub.lyrics.epoch)") {
            // Coming back to this tab for the same song keeps its translation and romanisation lines (resetting them changed the row heights under the reader).
            let key = "\(track?.uid ?? "")#\(hub.lyrics.epoch)"
            if MusicLyricsPanelMemory.lastKey != key { translation.reset() }
            MusicLyricsPanelMemory.lastKey = key
            if let t = track {
                hub.lyrics.ensureLoaded(t)
                if let l = lyrics { MusicLyricsExtrasRequest.request(hub: hub, track: t, lyrics: l) }
            }
        }
        // A new song's lyrics arriving while the romanisation or translation switch is on: ask for the extra line then, not only when the switch flips.
        .onChange(of: foundKey, initial: true) { old, key in if key != nil, let t = track, let l = lyrics { if old != nil, old != key { translation.reset() }; MusicLyricsExtrasRequest.request(hub: hub, track: t, lyrics: l) } }
        .onChange(of: hub.lyrics.updateCount) { _, _ in
            guard let t = track else { return }
            let shown = lyrics
            Task { await hub.lyrics.refreshAfterUpdate(for: t, shown: shown, stillCurrent: { track?.uid == t.uid }) }
        }
        .onChange(of: track?.uid) { _, _ in
            // A sheet built for the last song must not outlive it: its picked lines belong to that song only.
            shareIndices = nil; editing = false
        }
        .onChange(of: MusicLyricsFindRequest.shared.token) { _, _ in consumeFindRequest() }
        .onChange(of: editRequest) { _, _ in if let t = track, MusicLyricsContribution.videoID(for: t, hub: hub) != nil { editing = true } }
        .onChange(of: settings) { _, new in hub.lyrics.apply(settings: new) }
        .onChange(of: settings.showRomanisation) { _, on in
            if on, let l = lyrics, !l.hasRomanization { translation.requestRomanization(of: l) }
        }
        .onAppear {
            hub.lyrics.apply(settings: hub.library.settings)
            consumeFindRequest()
        }
        .sheet(isPresented: Binding(get: { shareIndices != nil }, set: { if !$0 { shareIndices = nil } })) {
            if let t = track, let l = lyrics, let picked = shareIndices {
                MusicLyricsShareSheet(track: t, lines: l.synced ?? [], picked: picked, subLines: subLines, onClose: { shareIndices = nil })
            }
        }
        .sheet(isPresented: $editing) {
            if let t = track, let vid = MusicLyricsContribution.videoID(for: t, hub: hub) {
                MusicLyricsEditorView(hub: hub, track: t, videoID: vid, startLyrics: lyrics.flatMap { $0.instrumental ? nil : $0 }, onClose: {
                    editing = false
                    Task { if let fresh = await hub.lyrics.lyrics(for: t) { hub.lyrics.adopt(fresh, for: t) } }
                }).atlasScreen("screen.music.lyricsEditor")
            }
        }
    }

    /// A "Find lyrics" pressed in the Now Playing preview lands here and opens the source search at once, so the person does not press it twice.
    private func consumeFindRequest() {
        guard MusicLyricsFindRequest.shared.take() else { return }
        Task { @MainActor in
            await Task.yield()
            findRequest += 1
        }
    }

    private var subLines: MusicLyricsSubLines? {
        if settings.showRomanisation, let s = translation.romanization.subLines { return s }
        if settings.showTranslation, let s = translation.translation.subLines { return s }
        return nil
    }

    @ViewBuilder
    private var main: some View {
        if let t = track {
            if loading {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: Localized.string(Self.loadingPhrase(for: t.uid))).font(Typography.caption).foregroundStyle(ink.opacity(0.55))
                    MusicLyricsSkeleton(ink: ink).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let l = lyrics, !l.isEmpty {
                if l.instrumental {
                    MusicEmptyState(symbol: "music.note", title: Localized.string("Instrumental"), message: Localized.string("This track has no words."))
                } else if let synced = l.synced, !synced.isEmpty {
                    MusicLyricsView(player: hub.player, lyrics: l, trackKey: t.uid, style: style, ink: ink,
                                    showTranslation: settings.showTranslation, showRomanisation: settings.showRomanisation, subLines: subLines,
                                    pickRequest: pickRequest, seekLocked: hub.room.controlsLocked, onShare: { shareIndices = $0 }, globalOffsetMs: hub.lyrics.globalOffsetMs)
                } else {
                    MusicLyricsPlainView(text: l.plain ?? "", ink: ink)
                }
            } else {
                missView(t)
            }
        } else {
            MusicEmptyState(symbol: "text.quote", title: Localized.string("Nothing playing"), message: Localized.string("Play a track to see its lyrics."))
        }
    }

    /// The terminal "no lyrics" state: why, the Find lyrics action (opens the source picker's search) and a quiet Search again.
    private func missView(_ t: MusicTrack) -> some View {
        var miss = MusicLyricsMiss.notFound
        if case .none(let m) = loadState { miss = m }
        let text: String
        switch miss {
        case .notFound: text = "No lyrics found for this track."
        case .mix: text = "Lyrics are not available for a mix."
        case .offline: text = "Could not reach the lyric sources."
        }
        return VStack(spacing: MusicSpace.sm) {
            Image(systemName: "text.quote").font(MusicTokens.iconLarge).foregroundStyle(ColorTokens.textTertiary)
                .frame(width: MusicSpace.giant + MusicSpace.xl, height: MusicSpace.giant + MusicSpace.xl)
                .background(ColorTokens.elevated, in: Circle()).accessibilityHidden(true)
            Text(verbatim: Localized.string(text)).font(Typography.heading).multilineTextAlignment(.center)
            if miss != .offline {
                Button(Localized.string("Find lyrics")) { findRequest += 1 }.musicButton(.primary)
                    .accessibilityLabel(Localized.string("Find lyrics for this track")).atlas("control.music.musicFindLyricsForThisTrack")
            }
            if miss == .offline {
                Button(Localized.string("Search again")) { translation.reset(); hub.lyrics.searchAgain(t) }
                    .musicButton(.primary).atlas("control.music.lyricsSearchAgain")
            } else {
                Button(Localized.string("Search again")) { translation.reset(); hub.lyrics.searchAgain(t) }
                    .musicButton(.secondary).atlas("control.music.lyricsSearchAgain")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ t: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let line = translation.statusLine(languageName: languageName)
            if let line { Text(verbatim: line).font(Typography.caption).foregroundStyle(ink.opacity(0.6)) }
            HStack(alignment: .center, spacing: 8) {
                MusicLyricsSourcePicker(hub: hub, track: t, lyrics: lyrics, findRequest: findRequest, showsLabel: !(lyrics?.isEmpty ?? true), onChanged: { setLyrics($0); translation.reset() }, onOpenEditor: { editing = true })
                    .id(t.uid)   // a new song gets a new picker: its checks, answers and pin belong to the song it was opened for
                Spacer(minLength: 0)
                MusicKaraokeSwitch(hub: hub)
            }
            if let l = lyrics, !l.isEmpty, !l.instrumental {
                MusicLyricsToolbar(hub: hub, track: t, lyrics: l, translation: translation, languageName: languageName,
                                   onOffsetChanged: { ms in if var cur = lyrics { cur.offsetMs = ms; cur.pinned = true; setLyrics(cur) } },
                                   onTranslate: { hub.library.settings.showTranslation = true; translation.requestTranslation(of: l, trackID: t.uid, target: MusicLyricsPrefs.effectiveTranslationLanguage(language)) },
                                   onShare: { pickRequest += 1 })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func loadingPhrase(for key: String) -> String { MusicLyricsLoadingPhrases.phrase(for: key) }
}

/// Runs the system translation session for the on-device translator when this system has one.
struct MusicLyricsTranslationHost: ViewModifier {
    let bridge: AnyObject?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, iOS 18.0, *), let b = bridge as? MusicAppleTranslationBridge {
            content.translationTask(b.configuration) { session in await b.serve(session) }
        } else { content }
        #else
        content
        #endif
    }
}

/// Unsynced lyrics: a plain column. Section labels in brackets become chips, blank lines become gaps.
struct MusicLyricsPlainView: View {
    let text: String
    let ink: Color
    @AppStorage(MusicLyricsPrefs.textStepKey) private var textStep = 1
    @AppStorage(MusicLyricsPrefs.alignmentKey) private var alignRaw = 0

    private var lineSize: Double { 26 * MusicLyricsPrefs.textSteps[min(max(0, textStep), MusicLyricsPrefs.textSteps.count - 1)] }
    private var align: MusicLyricsAlignment { MusicLyricsAlignment(rawValue: alignRaw) ?? .automatic }
    private var hAlign: HorizontalAlignment { align == .center ? .center : (align == .end ? .trailing : .leading) }
    private var frameAlign: Alignment { align == .center ? .center : (align == .end ? .trailing : .leading) }
    private var textAlign: TextAlignment { align == .center ? .center : (align == .end ? .trailing : .leading) }

    enum Row: Equatable { case header(String), line(String), gap }

    static func rows(_ text: String) -> [Row] {
        text.components(separatedBy: .newlines).map { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .gap }
            if t.hasPrefix("["), t.hasSuffix("]"), t.count > 2 { return .header(String(t.dropFirst().dropLast())) }
            return .line(t)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: hAlign, spacing: 6) {
                let rows = Self.rows(text)
                ForEach(rows.indices, id: \.self) { i in
                    switch rows[i] {
                    case .gap: Color.clear.frame(height: 14)
                    case .header(let h):
                        Text(verbatim: h.uppercased()).font(.system(size: 11.5, weight: .bold)).tracking(1.3).foregroundStyle(ink.opacity(0.9))
                            .padding(.horizontal, 11).padding(.vertical, 4).background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.top, i == 0 ? 6 : 24).padding(.bottom, 2)
                    case .line(let l): Text(verbatim: l).font(.system(size: lineSize, weight: .heavy)).multilineTextAlignment(textAlign).foregroundStyle(ink.opacity(0.95)).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlign).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}

/// What the lyrics tab remembers between visits, so that switching tabs does not start it over.
@MainActor
enum MusicLyricsPanelMemory { static var lastKey = "" }
