import SwiftUI

// The pieces under a long song list: the cached snapshot of what is shown, a counter of the rows on screen that does not redraw the list, and the
// compact and table rows.

enum MusicTrackRowStyle: Sendable, Equatable { case standard, compact, table }

/// The filtered and ordered list of a `MusicTrackList`, with the things every row needs, worked out once per change of the input. Keeping it in a
/// plain object means a body pass (every scroll step used to cause one) reads it instead of sorting and mapping a long list again.
@MainActor
final class MusicTrackListCache {
    struct Snapshot {
        var list: [MusicTrack] = []
        var indexed: [(offset: Int, element: MusicTrack)] = []
        var uids: [String] = []
        var position: [String: Int] = [:]
        var cells = MusicTrackCells.Data.all
        var signature = ""
    }

    private var key = ""
    private var snap = Snapshot()

    /// Short lists are hashed in full; a long one is sampled at 64 places plus both ends (the Library hands over a new array on every real change).
    static func key(tracks: [MusicTrack], filter: String, ordering: MusicTrackOrdering, presorted: Bool) -> String {
        var h = Hasher()
        let n = tracks.count
        if n <= 5000 { for t in tracks { h.combine(t.uid) } }
        else {
            let step = max(1, n / 64)
            for i in stride(from: 0, to: n, by: step) { h.combine(tracks[i].uid) }
            h.combine(tracks[n - 1].uid)
        }
        h.combine(filter); h.combine(ordering.encoded); h.combine(presorted)
        return "\(n)-\(h.finalize())"
    }

    func snapshot(tracks: [MusicTrack], filter: String, ordering: MusicTrackOrdering, presorted: Bool) -> Snapshot {
        let k = Self.key(tracks: tracks, filter: filter, ordering: ordering, presorted: presorted)
        if k == key { return snap }
        let list = presorted ? tracks : ordering.apply(MusicTrackFilter.apply(tracks, query: filter))
        var position: [String: Int] = [:]
        position.reserveCapacity(list.count)
        for (i, t) in list.enumerated() { position[t.uid] = i }
        snap = Snapshot(list: list, indexed: Array(list.enumerated()), uids: list.map(\.uid), position: position,
                        cells: MusicTrackCells.data(for: list), signature: k)
        key = k
        return snap
    }
}

/// Which rows are on screen. A plain object: changing it redraws nothing; `touch` tells the list after a short pause, so a flick through
/// thousands of rows costs a handful of updates instead of one per row.
@MainActor
final class MusicVisibleRows {
    var rows: Set<Int> = []
    private var pending: Task<Void, Never>?

    func touch(_ notify: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { notify() }
        }
    }
    func cancel() { pending?.cancel(); pending = nil }
}

// MARK: - rows

enum MusicLibraryRowMetrics {
    static let compactHeight: CGFloat = MusicSpace.xxl
    static let tableHeight: CGFloat = MusicSpace.huge
    static let indexWidth: CGFloat = MusicSpace.xxl
    static let coverSize: CGFloat = MusicSpace.xl
    static let durationWidth: CGFloat = MusicSpace.giant + MusicSpace.xs
}

/// A song as one dense line. Compact: number, title and artist side by side, length. Table: number, cover, title, artist, album, length in columns.
/// Click plays from here (or picks while picking, or with Cmd or Shift); the song menu opens with a secondary click and builds only then.
struct MusicLibraryDenseRow: View {
    let track: MusicTrack
    let index: Int
    let queue: [MusicTrack]
    let hub: MusicHub
    let style: MusicTrackRowStyle
    let columns: MusicTrackColumns
    var options = MusicRowOptions()
    var hostRemove: (label: String, action: () -> Void)?
    @State private var hovering = false
    @Environment(\.reddyAccent) private var accent

    private var isCurrent: Bool { hub.player.current?.uid == track.uid }
    private var height: CGFloat { style == .table ? MusicLibraryRowMetrics.tableHeight : MusicLibraryRowMetrics.compactHeight }

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            lead
            if style == .table { MusicArtwork(track: track, size: MusicLibraryRowMetrics.coverSize, corner: MusicCorner.control) }
            Text(verbatim: MusicDisplayTitle.display(for: track)?.title ?? track.title).musicText(.body).foregroundStyle(isCurrent ? accent : ColorTokens.textPrimary).lineLimit(1)
                .help(MusicDisplayTitle.display(for: track)?.raw ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if style == .compact, columns.has(.artist) {
                MusicTrackArtistLine(track: track, hub: hub, font: MusicTypeRole.secondary.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if style == .table {
                if columns.has(.artist) {
                    MusicTrackArtistLine(track: track, hub: hub, font: MusicTypeRole.secondary.font)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if columns.has(.album) {
                    Text(verbatim: track.album?.title ?? "").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let detail = options.trailingDetail {
                Text(verbatim: detail).musicText(.secondary).monospacedDigit().foregroundStyle(ColorTokens.textTertiary).lineLimit(1).fixedSize()
            }
            if columns.has(.duration) {
                Text(verbatim: track.durationMs > 0 ? MusicTime.clock(ms: track.durationMs) : "").musicText(.secondary).monospacedDigit()
                    .foregroundStyle(ColorTokens.textTertiary).frame(width: MusicLibraryRowMetrics.durationWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, MusicSpace.sm)
        .frame(height: height)
        .background(rowFill, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate() }
        .contextMenu { MusicTrackMenuContent(track: track, hub: hub, hostRemove: hostRemove) }
        .onAppear { options.onAppear?() }
        .onDisappear { options.onDisappear?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [track.title, track.displayArtistLine].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(options.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .atlasCovers("control.music.libraryRow")
    }

    private var rowFill: Color {
        options.isSelected || hovering ? ColorTokens.elevated : Color.clear
    }

    @ViewBuilder private var lead: some View {
        ZStack {
            if options.selecting {
                Image(systemName: options.isSelected ? "checkmark.circle.fill" : "circle").font(MusicTokens.iconSmall)
                    .foregroundStyle(options.isSelected ? accent : ColorTokens.textTertiary)
            } else if isCurrent {
                MusicCurrentRowGlyph(isPlaying: hub.player.isPlaying)
            } else if hovering {
                Image(systemName: "play.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textPrimary)
            } else {
                Text(verbatim: String(index + 1)).musicText(.secondary).monospacedDigit().foregroundStyle(ColorTokens.textTertiary)
            }
        }
        .frame(width: MusicLibraryRowMetrics.indexWidth)
    }

    private func activate() {
        if options.selecting || MusicClickModifiers.current != .plain {
            if options.handleClick?(track, MusicClickModifiers.current) == true { return }
        }
        hub.play(queue, at: index)
    }
}

/// The column titles above table rows; same structure as the row so the columns line up.
struct MusicLibraryTableHeader: View {
    let columns: MusicTrackColumns
    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            Text(verbatim: "#").frame(width: MusicLibraryRowMetrics.indexWidth)
            Color.clear.frame(width: MusicLibraryRowMetrics.coverSize, height: 1)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            if columns.has(.artist) { Text("Artist").frame(maxWidth: .infinity, alignment: .leading) }
            if columns.has(.album) { Text("Album").frame(maxWidth: .infinity, alignment: .leading) }
            if columns.has(.duration) { Text("Length").frame(width: MusicLibraryRowMetrics.durationWidth, alignment: .trailing) }
        }
        .musicText(.caption).foregroundStyle(ColorTokens.textTertiary).padding(.horizontal, MusicSpace.sm).padding(.bottom, MusicSpace.xxs)
        .accessibilityHidden(true)
    }
}
