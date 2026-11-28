import SwiftUI

// The album's artwork gallery and the person's own notes sheet. The gallery reads the Cover Art Archive index of the release (or its release group) by the
// MusicBrainz id the graph already holds, shows small pictures lazily and loads a large one only for the picture that is open. No source is named.

extension MusicAlbumReads {
    /// The MusicBrainz ids the graph holds for this album: a release id (from a release of the family) and a release-group id.
    static func artworkIDs(_ r: MusicSoundtrackReader, entity: MusicEntityID) async -> (release: String?, releaseGroup: String?) {
        let family = await r.family(of: entity)
        var release: String?, group: String?
        for m in family.members {
            for x in (try? await r.store.externalIDs(of: m)) ?? [] {
                if x.scheme == .mbReleaseGroup { group = group ?? x.value }
                else if x.scheme == .mbid, m.kind == .release { release = release ?? x.value }
            }
        }
        return (release, group)
    }
}

@MainActor @Observable
final class MusicAlbumArtworkModel {
    enum Phase { case idle, loading, loaded }
    private(set) var images: [MusicAlbumArtImage] = []
    private(set) var phase = Phase.idle
    @ObservationIgnored private var requested: MusicEntityID?
    @ObservationIgnored private var generation = 0

    /// Reads the index once per album. Cancelling the caller (the viewer closing) stops it and lets a later open try again.
    /// Only a finished read of the same album is not repeated; a read still marked loading may be a cancelled one, so a reopen starts again.
    nonisolated static func shouldStart(phase: Phase, requested: MusicEntityID?, entity: MusicEntityID) -> Bool {
        phase != .loaded || requested != entity
    }

    func load(entity: MusicEntityID) async {
        // A load still marked `.loading` may belong to a viewer that has already closed (its cancel has not landed yet): a reopen must start its own read
        // instead of returning early and leaving the gallery empty. Each read owns a generation; an older one never writes state.
        guard Self.shouldStart(phase: phase, requested: requested, entity: entity) else { return }
        generation &+= 1
        let mine = generation
        requested = entity
        phase = .loading
        let ids = await MusicAlbumReads.artworkIDs(MusicSoundtrackReader(MusicEntityRuntime.shared.store.graph), entity: entity)
        guard mine == generation else { return }
        guard !Task.isCancelled else { phase = .idle; return }
        guard let transport = MusicEntityArtwork.shared.transportIfAllowed() else { phase = .idle; return }
        var answered = false
        for address in MusicAlbumArtIndex.indexAddresses(release: ids.release, releaseGroup: ids.releaseGroup) {
            guard let url = URL(string: address) else { continue }
            guard let data = try? await transport.get(url, query: [:], headers: MusicSourceKit.headers) else {
                if mine != generation { return }
                if Task.isCancelled { phase = .idle; return }
                continue
            }
            if mine != generation { return }
            answered = true
            let found = MusicAlbumArtIndex.parse(data)
            if !found.isEmpty { images = found; break }
        }
        guard mine == generation else { return }
        guard !Task.isCancelled else { phase = .idle; return }
        // Nothing answered (every address failed): the viewer may try again the next time it opens.
        phase = answered ? .loaded : .idle
    }
}

// MARK: viewer

/// The cover viewer: the album's own cover first, then the other pictures of the release (back, booklet, disc...) when the archive holds them. Previous and
/// next, a strip of small pictures, and zoom. A picture the archive does not have is simply not there.
struct MusicAlbumCoverViewer: View {
    let thumbs: [MusicThumbnail]
    let title: String
    var entity: MusicEntityID? = nil
    var gallery: MusicAlbumArtworkModel? = nil
    let close: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var index = 0

    private struct Page: Identifiable {
        var id: String
        var label: String
        var main: [MusicThumbnail]
        var strip: [MusicThumbnail]
    }

    private func label(_ k: MusicAlbumArtKind) -> String {
        switch k {
        case .front: Localized.string("Front cover")
        case .back: Localized.string("Back cover")
        case .booklet: Localized.string("Booklet")
        case .medium: Localized.string("Disc")
        case .other: Localized.string("More artwork")
        }
    }

    private var pages: [Page] {
        var out: [Page] = []
        if !thumbs.isEmpty { out.append(Page(id: "cover", label: label(.front), main: thumbs, strip: thumbs)) }
        for img in gallery?.images ?? [] where !(img.kind == .front && !out.isEmpty) {
            let small = MusicThumbnail(url: img.thumb, width: 500, height: 500)
            out.append(Page(id: img.id, label: label(img.kind), main: [MusicThumbnail(url: img.full, width: 1200, height: 1200), small], strip: [small]))
        }
        return out
    }

    var body: some View {
        let pages = self.pages
        let current = pages.isEmpty ? 0 : min(index, pages.count - 1)
        VStack(spacing: MusicSpace.md) {
            HStack(spacing: MusicSpace.xs) {
                VStack(alignment: .leading, spacing: MusicSpace.xxs / 2) {
                    Text(verbatim: title).font(MusicTokens.sheetTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
                    if pages.count > 1 {
                        Text(verbatim: Localized.string("%1$@ · Picture %2$@ of %3$@", pages[current].label, String(current + 1), String(pages.count)))
                            .musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                    }
                }
                Spacer()
                if pages.count > 1 {
                    Button { step(-1, count: pages.count) } label: { Image(systemName: "chevron.left") }.musicButton(.glassIcon, size: .regular)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .accessibilityLabel(Localized.string("Previous picture")).atlas("control.music.albumArtworkPrevious")
                    Button { step(1, count: pages.count) } label: { Image(systemName: "chevron.right") }.musicButton(.glassIcon, size: .regular)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .accessibilityLabel(Localized.string("Next picture")).atlas("control.music.albumArtworkNext")
                }
                Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }.musicButton(.glassIcon, size: .regular)
                    .disabled(zoom <= 1).accessibilityLabel(Localized.string("Zoom out")).atlas("control.music.albumCoverZoomOut")
                Button { zoom = min(4, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }.musicButton(.glassIcon, size: .regular)
                    .disabled(zoom >= 4).accessibilityLabel(Localized.string("Zoom in")).atlas("control.music.albumCoverZoomIn")
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.albumCoverClose")
            }
            if pages.isEmpty {
                MusicEmptyState(glyph: .note, title: Localized.string("No artwork for this album yet."), message: "")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    MusicArtwork(pages[current].main, size: 520 * zoom, corner: MusicCorner.cardLarge).padding(MusicSpace.xs)
                }
                .id(pages[current].id)
            }
            if pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MusicSpace.xs) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                            Button { index = i; zoom = 1 } label: {
                                MusicArtwork(p.strip, size: MusicSpace.giant, corner: MusicCorner.control)
                                    .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(i == current ? ColorTokens.accent : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain).accessibilityLabel(p.label).atlas("control.music.albumArtworkPage")
                        }
                    }
                    .padding(.vertical, MusicSpace.xxs)
                }
                .frame(height: MusicSpace.giant + MusicSpace.sm)
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 560, minHeight: 600)
        .task { if let e = entity, let g = gallery { await g.load(entity: e) } }
    }

    private func step(_ by: Int, count: Int) {
        guard count > 0 else { return }
        index = (min(index, count - 1) + by + count) % count
        zoom = 1
    }
}

// MARK: your rating, notes and tags

/// The person's own rating, note and collection tags for the album. Kept on this device only.
struct MusicAlbumPersonalSheet: View {
    let extras: MusicAlbumExtrasModel
    let title: String
    let close: () -> Void
    @State private var rating: Int?
    @State private var note: String
    @State private var tagsText: String

    init(extras: MusicAlbumExtrasModel, title: String, close: @escaping () -> Void) {
        self.extras = extras; self.title = title; self.close = close
        _rating = State(initialValue: extras.rating)
        _note = State(initialValue: extras.note)
        _tagsText = State(initialValue: extras.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(verbatim: title).font(MusicTokens.sheetTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.albumPersonalClose")
            }
            Text("Your rating").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            HStack(spacing: MusicSpace.xxs) {
                ForEach(1...MusicAlbumPersonal.maxRating, id: \.self) { n in
                    Button { rating = rating == n ? nil : n } label: {
                        Image(systemName: (rating ?? 0) >= n ? "star.fill" : "star").font(MusicTokens.iconLarge)
                            .foregroundStyle((rating ?? 0) >= n ? ColorTokens.accent : ColorTokens.textTertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(Localized.string("Rate %@ of 5", String(n))).atlas("control.music.albumRatingStar")
                }
            }
            Text("Collection tags").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            TextField(Localized.string("Separate tags with commas"), text: $tagsText).textFieldStyle(.roundedBorder).atlas("control.music.albumTagsField")
            Text("Your notes").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            TextEditor(text: $note).musicText(.body).frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous).strokeBorder(ColorTokens.line))
                .accessibilityLabel(Localized.string("Your notes")).atlas("control.music.albumNotesField")
            Text("Kept on this device only.").musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            HStack {
                Spacer()
                Button(Localized.string("Save")) { save(); close() }.musicButton(.secondary, size: .regular).disabled(!extras.canChoose).atlas("control.music.albumPersonalSave")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 420, minHeight: 440)
    }

    private func save() {
        extras.setRating(rating)
        extras.setTags(MusicAlbumPersonal.parseTags(tagsText))
        extras.setNote(note)
    }
}
