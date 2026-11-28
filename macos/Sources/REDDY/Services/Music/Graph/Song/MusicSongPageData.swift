import Foundation

/// How a part that is not a graph section (provider suggestions, the source search) is doing.
enum MusicSongLoad: Equatable, Sendable { case idle, loading, loaded }

/// Everything the song page draws, derived from the section states in one pure place: the items of each block, which blocks show and in which state,
/// and what is left out because another block already shows it (a version is not also a "related song"). Foundation-only, so the rules are tested
/// without any view.
struct MusicSongPageData: Sendable {
    var sections: [MusicSongSectionKey: MusicEntitySection] = [:]
    var providerRelated: [MusicTrack] = []
    var providerState: MusicSongLoad = .idle
    var providerName: String = ""
    /// The page has a real provider row to ask suggestions for.
    var providerAvailable = false
    var localPlaylists: [MusicSongPlaylistItem] = []
    var selfID: MusicEntityID
    var selfName: String = ""
    /// The page has a row to look sources up for (a track, or its stand-in).
    var hasMatchBase = false
    var sourcesState: MusicSongLoad = .idle
    var lyricsFinishedWithNothing = false

    init(selfID: MusicEntityID) { self.selfID = selfID }

    private func section(_ k: MusicSongSectionKey) -> MusicEntitySection { sections[k] ?? MusicEntitySection(key: k.loaderKey) }

    // MARK: items

    var context: MusicSongContext? { section(.context).items(MusicSongContext.self).first }
    var creditGroups: [MusicSongCreditGroup] { section(.credits).items(MusicSongCreditGroup.self).filter { !$0.people.isEmpty } }
    var versionItems: [MusicSongVersionItem] { section(.versions).items(MusicSongVersionItem.self) }
    var versionGroups: [MusicSongVersionGroup] { MusicSongVersioning.group(versionItems, excluding: selfID) }
    /// Sampling is one directed link, sampling recording to sampled source: "samples from" are this song's outgoing links, "sampled by" its incoming ones.
    var sampleItems: [MusicSongSampleItem] { section(.samples).items(MusicSongSampleItem.self) }
    var samplesFrom: [MusicSongSampleItem] { sampleItems.filter { $0.direction == .samplesFrom } }
    var sampledBy: [MusicSongSampleItem] { sampleItems.filter { $0.direction == .sampledBy } }
    var liveItems: [MusicSongVersionItem] { MusicSongVersioning.liveItems(versionItems, excluding: selfID) }
    private var versionIDs: Set<MusicEntityID> { Set(versionItems.map(\.id)).union([selfID]) }

    var related: [MusicSongRelatedItem] {
        let graph = section(.related).items(MusicSongRelatedItem.self).filter { !versionIDs.contains($0.id) }
        return MusicSongRelated.merge(graph: graph, provider: providerRelated, providerName: providerName, excluding: versionIDs, selfName: selfName)
    }
    private var relatedIDs: Set<MusicEntityID> { Set(related.map(\.id)) }

    var moreBySinger: [MusicSongRelatedItem] { section(.moreBySinger).items(MusicSongRelatedItem.self).filter { !versionIDs.contains($0.id) } }
    var moreByComposer: [MusicSongRelatedItem] { section(.moreByComposer).items(MusicSongRelatedItem.self).filter { !versionIDs.contains($0.id) } }
    var films: [MusicSongRelatedItem] { section(.films).items(MusicSongRelatedItem.self) }
    var similar: [MusicSongRelatedItem] { section(.similar).items(MusicSongRelatedItem.self).filter { !versionIDs.contains($0.id) && !relatedIDs.contains($0.id) } }
    var playlists: [MusicSongPlaylistItem] { MusicSongPlaylists.combine(local: localPlaylists, provider: section(.playlists).items(MusicSongPlaylistItem.self)) }

    // MARK: block states

    private func graphState(_ k: MusicSongSectionKey, count: Int, quiet: Bool = false) -> MusicSongBlockState {
        MusicSongVisibility.state(phase: section(k).phase, itemCount: count, quietWhenEmpty: quiet)
    }

    func state(_ b: MusicSongBlock) -> MusicSongBlockState {
        switch b {
        case .header: return .content
        case .credits: return graphState(.credits, count: creditGroups.count, quiet: MusicSongVisibility.quietWhenEmpty(.credits))
        case .lyrics: return .content
        case .versions: return graphState(.versions, count: versionGroups.count)
        case .samples: return graphState(.samples, count: sampleItems.count)
        case .live:
            // Live performances appear only once the versions have been read, and only when an edge types one as live.
            let p = section(.versions).phase
            return (p == .loaded || p == .partial || p == .failed) && !liveItems.isEmpty ? .content : .hidden
        case .related:
            if !related.isEmpty { return .content }
            let g = section(.related).phase
            let graphDone = g == .loaded || g == .empty || g == .failed
            // The provider is asked when the block first shows; with no row to ask for, there is nothing to wait for.
            let providerDone = !providerAvailable || providerState == .loaded
            return graphDone && providerDone ? .hidden : .skeleton
        case .moreBySinger: return graphState(.moreBySinger, count: moreBySinger.count)
        case .moreByComposer: return graphState(.moreByComposer, count: moreByComposer.count)
        case .films: return graphState(.films, count: films.count)
        case .playlists:
            if !playlists.isEmpty { return .content }
            return graphState(.playlists, count: 0)
        case .similar: return graphState(.similar, count: similar.count)
        case .sources: return hasMatchBase ? .content : .hidden
        }
    }

    /// The blocks to draw under the header, in order; a hidden block takes no room.
    var visibleBlocks: [MusicSongBlock] { MusicSongBlock.order.filter { $0 != .header && state($0) != .hidden } }

    /// True when the page has nothing at all beyond its header (the header alone is a fine page for a bare song).
    var isBare: Bool { visibleBlocks.allSatisfy { [.lyrics, .sources].contains($0) } }
}
