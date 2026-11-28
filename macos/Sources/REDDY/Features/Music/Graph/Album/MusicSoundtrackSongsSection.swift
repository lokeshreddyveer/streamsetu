import SwiftUI

// Section B: the songs of THIS release. The rows come from the provider's tracklist, so each one plays at once; the singer line is refined from the
// graph in place (a fixed line box, so nothing moves). A row plays on click or Return; "Song details" opens the song page for that recording (route
// `.song`). A song the graph knows but the provider did not list is shown too, opens its details, and says it cannot be played from here.

struct MusicSoundtrackSongsSection: View {
    let page: MusicSoundtrackPageModel
    /// Which row has the keyboard: Up and Down move it, Home and End jump, Return plays (the pattern of a list).
    @FocusState private var focusedRow: MusicEntityID?

    private func move(from id: MusicEntityID, by step: Int, toEnd: Bool = false) {
        let ids = page.rows.map(\.id)
        guard let i = ids.firstIndex(of: id), !ids.isEmpty else { return }
        focusedRow = toEnd ? (step < 0 ? ids.first : ids.last) : ids[max(0, min(ids.count - 1, i + step))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if page.rows.isEmpty, page.songsState == .idle || page.songsState == .loading {
                VStack(spacing: MusicSpace.xxs) { ForEach(0..<6, id: \.self) { _ in MusicSkeletonRow() } }.accessibilityHidden(true)
            } else if page.rows.isEmpty, page.songsState == .failed {
                MusicErrorState(title: Localized.string("Could not load the songs"), message: Localized.string("Check your connection and try again."),
                                retryTitle: Localized.string("Try again")) { page.retrySongs() }
            } else if page.rows.isEmpty, page.songsState == .empty {
                // The source answered with no songs: usually the album is not sold in this country's store, which is not the same as a failed request.
                MusicEmptyState(symbol: "globe", title: Localized.string("No songs for this album here"),
                                message: page.storefrontName.map { Localized.string("The source lists no songs for this album in %@. Try again, or choose another country.", $0) }
                                    ?? Localized.string("The source lists no songs for this album. Try again in a moment."),
                                actionTitle: Localized.string("Try again")) { page.retrySongs() }
            } else if page.rows.isEmpty, page.songsState == .noEdition {
                MusicEmptyState(symbol: "music.note.list", title: Localized.string("No songs for this album yet"),
                                message: Localized.string("This album has no playable edition here yet. Try again later."),
                                actionTitle: Localized.string("Try again")) { page.retrySongs() }
            } else if !page.rows.isEmpty {
                let groups = MusicSoundtrackSongs.discs(page.rows)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    if groups.count > 1, let d = g.disc {
                        Label(Localized.string("Disc %@", "\(d)"), systemImage: "opticaldisc").musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                            .padding(.leading, MusicSpace.xs).padding(.top, MusicSpace.xs).accessibilityAddTraits(.isHeader)
                    }
                    ForEach(g.rows) { row in MusicSoundtrackSongRowView(page: page, row: row, focus: $focusedRow, move: { step, end in move(from: row.id, by: step, toEnd: end) }) }
                }
                if page.songsNeedRetry {
                    HStack(spacing: MusicSpace.xs) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                        Text(Localized.string("Some songs could not be loaded.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                        Button(Localized.string("Try again")) { page.retrySongs() }.musicButton(.tertiary, size: .compact, accentText: true).atlas("control.music.soundtrackSongsRetry")
                    }
                    .padding(.horizontal, MusicSpace.xs).padding(.top, MusicSpace.xs)
                }
            }
        }
    }
}

struct MusicSoundtrackSongRowView: View {
    let page: MusicSoundtrackPageModel
    let row: MusicSoundtrackSongRow
    var focus: FocusState<MusicEntityID?>.Binding
    var move: (Int, Bool) -> Void
    /// Composer and lyricist of THIS recording, only when the recording itself carries them (the album page passes them; nil elsewhere).
    var makers: MusicAlbumTrackMakers? = nil
    /// Multi-select (the album's Tracks pill): while `selecting`, a click toggles the row instead of playing it.
    var selecting = false
    var selected = false
    var toggleSelect: (() -> Void)? = nil
    /// The songs in the order the person sees them (a sorted or filtered Tracks view): a click plays that list from this row. Nil plays the whole album.
    var playList: [MusicTrack]? = nil
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hub: MusicHub { page.hub }
    private var track: MusicTrack? { page.track(for: row) }
    private var isCurrent: Bool { row.trackUID != nil && hub.player.current?.uid == row.trackUID }
    private static let numberWidth = MusicSpace.xl + MusicSpace.xxs
    private static let rowHeight = MusicSpace.giant + MusicSpace.xs

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Button(action: primary) {
                HStack(spacing: MusicSpace.sm) {
                    Group {
                        if selecting { Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(MusicTokens.iconMedium).foregroundStyle(selected ? ColorTokens.accent : ColorTokens.textTertiary) }
                        else if isCurrent { MusicCurrentRowGlyph(isPlaying: hub.player.isPlaying) }
                        else { Text(verbatim: "\(row.number)").musicText(.secondary).monospacedDigit().foregroundStyle(ColorTokens.textTertiary) }
                    }
                    .frame(width: Self.numberWidth, alignment: .trailing)
                    VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                        Text(verbatim: row.title).musicText(.card).lineLimit(1).foregroundStyle(isCurrent ? ColorTokens.accent : ColorTokens.textPrimary)
                            .fontWeight(isCurrent ? .semibold : .regular)
                        // a fixed line box: the singers arriving later change the words, never the height
                        Text(verbatim: captionLine).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary)
                            .frame(minHeight: MusicCardGeometry.subtitleLineHeight, alignment: .leading)
                    }
                    Spacer(minLength: MusicSpace.xs)
                    if !row.isPlayable {
                        Text("Not playable from here").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                    indicators
                    if row.durationMs > 0 { Text(verbatim: Self.duration(row.durationMs)).musicText(.secondary).monospacedDigit().foregroundStyle(ColorTokens.textTertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable().focused(focus, equals: row.id).focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, false); return .handled }
            .onKeyPress(.upArrow) { move(-1, false); return .handled }
            .onKeyPress(.home) { move(-1, true); return .handled }
            .onKeyPress(.end) { move(1, true); return .handled }
            .onKeyPress(.return) { primary(); return .handled }
            .accessibilityLabel(spoken)
            .accessibilityHint(row.isPlayable ? Localized.string("Plays this song") : Localized.string("Opens the song details"))
            .musicCurrentRowMarker(isCurrent: isCurrent, isPlaying: hub.player.isPlaying)
            .atlas("control.music.soundtrackSongRow")

            Button { hub.open(row.id) } label: { Image(systemName: "info.circle").font(MusicTokens.iconMedium) }
                .musicButton(.icon, size: .compact)
                .accessibilityLabel(Localized.string("Song details for %@", row.title)).musicTooltip(verbatim: Localized.string("Song details"))
                .atlas("control.music.soundtrackSongDetails")
        }
        .padding(.horizontal, MusicSpace.xs)
        .frame(minHeight: Self.rowHeight)
        .background(hovering || focus.wrappedValue == row.id ? ColorTokens.elevated : Color.clear, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            if let track {
                Button(Localized.string("Play"), systemImage: "play.fill") { playRow() }
                    .atlas("control.music.soundtrackSongRow")
                MusicTrackMenuContent(track: track, hub: hub)
                Divider()
            }
            Button(Localized.string("Song details"), systemImage: "info.circle") { hub.open(row.id) }
                .atlas("control.music.soundtrackSongDetails")
        }
        .atlasCovers("control.music.soundtrackSongRow")
    }

    /// Small marks a row wears when they are true: explicit, a favourite, kept offline. Each is read from the app's own state, nothing is guessed.
    private var isFavourite: Bool { track.map { hub.library.isLiked($0) } ?? false }
    private var isOffline: Bool { row.trackUID.map { uid in hub.downloads.items.contains { $0.id == uid && $0.state == .done } } ?? false }

    @ViewBuilder private var indicators: some View {
        HStack(spacing: MusicSpace.xxs) {
            if row.explicit { Image(systemName: "e.square.fill") }
            if isFavourite { Image(systemName: "heart.fill").foregroundStyle(ColorTokens.accent) }
            if isOffline { Image(systemName: "arrow.down.circle.fill") }
        }
        .font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
    }

    /// The singers, then which edition this row is when the album repeats the title.
    private var captionLine: String {
        var parts = [row.singerLine].filter { !$0.isEmpty }
        if case .repeated(let n)? = row.edition { parts.append(Localized.string("Edition %1$@", String(n))) }
        if let m = makers {
            if !m.composers.isEmpty { parts.append(Localized.string("Music: %@", m.composers.prefix(2).joined(separator: ", "))) }
            if !m.lyricists.isEmpty { parts.append(Localized.string("Lyrics: %@", m.lyricists.prefix(2).joined(separator: ", "))) }
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func primary() {
        if selecting { toggleSelect?(); return }
        if row.isPlayable { playRow() } else { hub.open(row.id) }
    }

    private func playRow() {
        if let list = playList, let uid = row.trackUID, let i = list.firstIndex(where: { $0.uid == uid }) { hub.play(list, at: i, sourceName: page.displayHeader?.title); return }
        page.play(row: row)
    }

    private var spoken: String {
        [row.title, captionLine.trimmingCharacters(in: .whitespaces), row.durationMs > 0 ? Self.duration(row.durationMs) : nil, row.isPlayable ? nil : Localized.string("Not playable from here"),
         row.explicit ? Localized.string("Explicit") : nil, isFavourite ? Localized.string("Favourite") : nil, isOffline ? Localized.string("Downloaded") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func duration(_ ms: Int64) -> String {
        let s = Int(max(0, ms) / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
