import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Item 9: the song's lyrics with translation and romanisation. The lyric service, the translation service and the romaniser are the existing ones;
/// this block only asks them for the page's song, when it comes into view (never on page load before that, and never while the page is offscreen).
/// Lyrics of the song that is playing use the app's shared translation service, so the panel and this block agree; lyrics of any other song use the
/// block's own service, so nothing is ever changed under the player's lyrics.
struct MusicSongLyricsBlock: View {
    let page: MusicSongPageModel

    private enum Mode { case original, translation, romanisation }
    private static let collapsedLines = 12

    @State private var mode: Mode = .original
    @State private var expanded = false
    @State private var local: MusicLyricsTranslationService

    init(page: MusicSongPageModel) {
        self.page = page
        _local = State(initialValue: MusicLyricsTranslationService(cacheDirectory: nil, translator: page.hub.translationBridge as? any MusicLyricsTextTranslator))
    }

    private struct Row: Identifiable { let id: Int; let line: MusicLyricLine }

    private var hub: MusicHub { page.hub }

    private func shared(_ t: MusicTrack) -> Bool { MusicSongLyricsLogic.usesSharedTranslation(pageTrackUID: t.uid, playingUID: hub.player.current?.uid) }
    private func service(_ t: MusicTrack) -> MusicLyricsTranslationService { shared(t) ? hub.translation : local }

    var body: some View {
        if let t = page.matchBase {
            let state = hub.lyrics.loadState(for: t)
            let lyrics: MusicLyrics? = { if case .found(let l) = state { return l }; return nil }()
            let display = MusicSongLyricsLogic.display(lyrics: lyrics, loading: state == .loading || state == .idle, finished: state.isTerminal, limit: expanded ? 10_000 : Self.collapsedLines)
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                HStack(spacing: MusicSpace.xs) {
                    MusicSongHeading(key: "Lyrics")
                    Spacer(minLength: MusicSpace.xs)
                    if let lyrics, case .lines(_, _, _) = display { controls(lyrics, t) }
                }
                content(display, lyrics, t)
            }
            .onAppear { if state == .idle { hub.lyrics.ensureLoaded(t) } }
            .onChange(of: t.uid) { _, _ in mode = .original; expanded = false; local.reset() }
            .onChange(of: shared(t)) { _, _ in mode = .original }
            .onDisappear { local.reset() }
            .modifier(MusicSongTranslationHost(bridge: hub.translationBridge))
        }
    }

    // MARK: states

    @ViewBuilder private func content(_ display: MusicSongLyricsLogic.Display, _ lyrics: MusicLyrics?, _ t: MusicTrack) -> some View {
        switch display {
        case .skeleton:
            VStack(alignment: .leading, spacing: MusicSpace.xs) { MusicSkeletonRow(cover: MusicSpace.lg); MusicSkeletonRow(cover: MusicSpace.lg); MusicSkeletonRow(cover: MusicSpace.lg) }
        case .instrumental:
            MusicSongQuietLine(key: "Instrumental")
        case .none(let missed):
            HStack(spacing: MusicSpace.xs) {
                MusicSongQuietLine(key: missed ? "No lyrics found" : "Lyrics have not been looked up yet")
                Button(Localized.string(missed ? "Search again" : "Find lyrics")) { hub.lyrics.searchAgain(t) }
                    .musicButton(.tertiary, size: .compact).atlas("control.music.songPageLyricsSearch")
            }
        case .lines(_, let total, _):
            if let lyrics { lines(lyrics, total: total, t) }
        }
    }

    private func lines(_ l: MusicLyrics, total: Int, _ t: MusicTrack) -> some View {
        let svc = service(t)
        let all = MusicLyricsSlots.lines(of: l)
        let sub: MusicLyricsSubLines? = mode == .translation ? svc.translation.subLines : (mode == .romanisation ? svc.romanization.subLines : nil)
        let rows: [Row] = {
            var out: [Row] = []
            var n = 0
            for (i, line) in all.enumerated() {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || (text.hasPrefix("[") && text.hasSuffix("]")) { continue }
                out.append(Row(id: i, line: line)); n += 1
                if !expanded && n >= Self.collapsedLines { break }
            }
            return out
        }()
        return VStack(alignment: .leading, spacing: MusicSpace.xs) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.line.text).musicText(.body).foregroundStyle(ColorTokens.textPrimary)
                    if let s = MusicLyricsPreviewLogic.subText(sub, index: row.id, original: row.line.text) {
                        Text(verbatim: s).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if mode != .original, let status = svc.statusLine(languageName: Locale.current.localizedString(forLanguageCode: svc.targetLanguage) ?? svc.targetLanguage) {
                Text(verbatim: status).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            HStack(spacing: MusicSpace.xs) {
                if total > Self.collapsedLines {
                    Button(Localized.string(expanded ? "Show fewer lines" : "Show all lyrics")) { expanded.toggle() }
                        .musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.songPageLyricsExpand")
                }
            }
        }
    }

    // MARK: translation and romanisation controls

    @ViewBuilder private func controls(_ l: MusicLyrics, _ t: MusicTrack) -> some View {
        let svc = service(t)
        let lines = MusicSongLyricsLogic.lines(of: l)
        HStack(spacing: MusicSpace.xxs) {
            MusicChip(title: Localized.string("Original"), selected: mode == .original) { mode = .original }
            if svc.isAvailable {
                MusicChip(title: Localized.string("Translation"), selected: mode == .translation) { mode = .translation; svc.requestTranslation(of: l, trackID: t.uid, target: nil) }
            }
            if MusicSongLyricsLogic.needsRomanisation(lines) {
                MusicChip(title: Localized.string("Romanised"), selected: mode == .romanisation) { mode = .romanisation; svc.requestRomanization(of: l) }
            }
        }
    }
}

/// Lets the system translator ask for its session from a view (a copy of the panel's host: that one is private to the lyrics panel).
private struct MusicSongTranslationHost: ViewModifier {
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
