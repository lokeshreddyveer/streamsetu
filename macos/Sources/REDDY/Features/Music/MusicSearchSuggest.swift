import SwiftUI
import Observation

/// What the person has typed so far, answered with a few live songs. The words typed go to the switched-on sources exactly as a search would, and
/// nothing else goes with them. A newer keystroke drops the older request.
@MainActor @Observable
final class MusicSuggestModel {
    private(set) var tracks: [MusicTrack] = []
    /// Offers from names already seen, ready on the keystroke itself, and the typed words with the wrong ones fixed.
    private(set) var local: [String] = []
    private(set) var correction: String?
    private(set) var loading = false
    private(set) var forQuery = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    static let fetchCap = 8

    func cancel() { task?.cancel(); task = nil; loading = false }
    func reset() { cancel(); tracks = []; local = []; correction = nil; forQuery = "" }

    func update(typed: String, registry: MusicRegistry) {
        task?.cancel()
        let q = MusicSuggest.trimmed(typed)
        guard MusicSuggest.qualifies(q) else { tracks = []; local = []; correction = nil; forQuery = ""; loading = false; return }
        let providers = registry.metadata
        loading = !providers.isEmpty
        if providers.isEmpty { tracks = [] }
        task = Task { [weak self] in
            // 1. Names already seen answer at once (no waiting, no network); fixing the spelling is part of it.
            let answer = await MusicLocalSuggestions.shared.suggest(q, limit: 6)
            if Task.isCancelled { return }
            self?.local = answer.suggestions.map(\.text)
            self?.correction = answer.correction
            guard !providers.isEmpty else { return }
            // 2. Songs from the sources: a short wait so a fast typist sends one request, then each source's answer is shown as it arrives, so the
            //    slowest source never decides how soon anything appears. The words the person typed AND their corrected spelling are asked.
            try? await Task.sleep(for: MusicSuggest.debounce)
            if Task.isCancelled { return }
            let asks = [q] + (answer.correction.map { [$0] } ?? [])
            var got: [Int: [MusicTrack]] = [:]
            await withTaskGroup(of: (Int, [MusicTrack]).self) { group in
                var slot = 0
                for ask in asks { for p in providers { let s = slot; slot += 1; group.addTask { (s, (try? await MusicSearchCache.run(provider: p, query: ask, kind: .songs, page: nil))?.results.compactMap { if case .track(let t) = $0 { t } else { nil } } ?? []) } } }
                for await (s, items) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    got[s] = items
                    let lists = got.keys.sorted().map { got[$0] ?? [] }
                    self?.tracks = Array(MusicSearchRanker.mergeTracks(lists, query: q).prefix(Self.fetchCap))
                    self?.forQuery = q
                }
            }
            if Task.isCancelled { return }
            guard let self else { return }
            // What came back teaches the suggestions: its titles and artists are offered (and spell-checked against) from now on.
            let names = self.tracks.flatMap { [$0.title] + $0.artists.map(\.name) }
            Task { await MusicLocalSuggestions.shared.add(names, kind: .other, weight: 1) }
            self.forQuery = q
            self.loading = false
        }
    }
}

/// The dropdown under the search field: the typed words first, completions with an arrow that fills the field, then a hairline and live songs.
struct MusicSuggestPanel: View {
    let hub: MusicHub
    let typed: String
    let rows: [MusicSuggestionRow]
    let loading: Bool
    @Binding var highlight: Int?
    let choose: (MusicSuggestionRow) -> Void
    let fill: (String) -> Void
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if case .track = row, i > 0, !isTrack(rows[i - 1]) { Divider().overlay(ColorTokens.line).padding(.vertical, 4) }
                rowView(row, index: i)
            }
            if loading && !rows.contains(where: isTrack) {
                // Placeholder rows with the shape of the songs that are coming, so the panel does not jump when they arrive.
                VStack(alignment: .leading, spacing: MusicSpace.xs) { ForEach(0..<3, id: \.self) { _ in MusicSkeletonRow(cover: MusicSpace.xl) } }
                    .padding(.horizontal, Spacing.md).padding(.vertical, MusicSpace.xs)
                    .musicSkeletonShimmer()
                    .accessibilityElement(children: .ignore).accessibilityLabel(Localized.string("Looking for songs…"))
            }
        }
        .padding(.vertical, 6)
        .background(ColorTokens.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
        .frame(maxWidth: 680)
        .accessibilityElement(children: .contain).accessibilityLabel("Suggestions")
    }

    private func isTrack(_ r: MusicSuggestionRow) -> Bool { if case .track = r { true } else { false } }

    @ViewBuilder private func rowView(_ row: MusicSuggestionRow, index i: Int) -> some View {
        let on = highlight == i
        switch row {
        case .search(let s):
            Button { choose(row) } label: {
                HStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary).frame(width: 22)
                    Text(verbatim: Localized.string("Search “%@”", s)).font(Typography.bodyMedium).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40).padding(.horizontal, Spacing.md).contentShape(Rectangle())
            }
            .buttonStyle(.plain).background(on ? accent.opacity(MusicTokens.flashFill) : .clear)
            .onHover { if $0 { highlight = i } }
            .accessibilityLabel("Search for \(s)").atlas("control.music.suggestSearch")
        case .correction(let s):
            Button { choose(row) } label: {
                HStack(spacing: 16) {
                    Image(systemName: "textformat.abc").font(MusicTokens.iconMedium).foregroundStyle(accent).frame(width: 22)
                    Text(verbatim: Localized.string("Did you mean “%@”?", s)).font(Typography.bodyMedium).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40).padding(.horizontal, Spacing.md).contentShape(Rectangle())
            }
            .buttonStyle(.plain).background(on ? accent.opacity(MusicTokens.flashFill) : .clear)
            .onHover { if $0 { highlight = i } }
            .accessibilityLabel("Search for \(s) instead").atlas("control.music.searchSearchFor")
        case .completion(let s):
            HStack(spacing: 0) {
                Button { choose(row) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "magnifyingglass").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textTertiary).frame(width: 22)
                        Text(verbatim: s).font(Typography.body).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 40).padding(.leading, Spacing.md).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Search for \(s)").atlas("control.music.searchSearchFor")
                Button { fill(s) } label: {
                    Image(systemName: "arrow.up.left").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.textSecondary)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverHighlight().accessibilityLabel("Put \(s) in the search field").help("Put in the search field")
                .atlas("control.music.suggestFill")
            }
            .background(on ? accent.opacity(MusicTokens.flashFill) : .clear)
            .onHover { if $0 { highlight = i } }
        case .track(let t):
            Button { choose(row) } label: {
                HStack(spacing: 12) {
                    MusicArtwork(track: t, size: 44, corner: MusicTokens.radiusRow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: t.title).font(Typography.bodyMedium).lineLimit(1).foregroundStyle(ColorTokens.textPrimary)
                        Text(verbatim: t.displayArtistLine).font(Typography.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4).padding(.horizontal, Spacing.md).contentShape(Rectangle())
            }
            .buttonStyle(.plain).background(on ? accent.opacity(MusicTokens.flashFill) : .clear)
            .onHover { if $0 { highlight = i } }
            .contextMenu { Button("Play", systemImage: "play.fill") { hub.play([t], at: 0) }.atlas("control.music.searchPlay"); MusicTrackMenuContent(track: t, hub: hub) }
            .accessibilityLabel("\(t.title), \(t.artistLine)").accessibilityHint("Plays this song").atlas("control.music.searchPlay")
        }
    }
}
