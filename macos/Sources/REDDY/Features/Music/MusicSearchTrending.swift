import SwiftUI
import Observation

/// Loads the Trending chips of the empty Search page for the person's chart country. It asks the same discovery sources, for the same country, as Explore
/// (through the shared saved copy, so it is usually answered without a request), turns the country's chart into chips (`MusicTrendingSearches.build`), and keeps
/// them in memory for the session and on disk for a few hours, so the empty page is instant on the next visit.
@MainActor @Observable final class MusicTrendingModel {
    enum Phase: Equatable { case loading, loaded([MusicTrendingSearches.Chip]), empty }

    private(set) var phase: Phase = .loading
    private(set) var region = ""
    private static var memory: [String: (at: Date, chips: [MusicTrendingSearches.Chip])] = [:]

    struct Source: Sendable { let provider: any MusicMetadataProvider; let regional: Bool; let follows: Bool }

    /// Drops what was kept in memory (after a privacy wipe).
    static func forget() { memory = [:] }

    func load(hub: MusicHub, region: String) async {
        let label = region.isEmpty ? "worldwide" : region
        if let hit = Self.memory[region], Date().timeIntervalSince(hit.at) < MusicTrendingSearches.freshFor {
            self.region = region
            phase = hit.chips.isEmpty ? .empty : .loaded(hit.chips)
            MusicDebugLog.log("search", "trending \(label): \(hit.chips.count) chips, session cache hit")
            return
        }
        // The same country's chips already on screen stay while they refresh; another country's never show under this one's name.
        if self.region != region { phase = .loading }
        self.region = region
        let sources = hub.registry.discovery.map { Source(provider: $0, regional: $0 is any MusicRegionalDiscovery, follows: MusicRegionalSources.followsRegion(providerID: $0.id, region: region)) }
        guard !sources.isEmpty else {
            phase = .empty
            MusicDebugLog.log("search", "trending \(label): no discovery source is switched on")
            return
        }
        let policy = MusicFetch.Policy(fresh: MusicTrendingSearches.freshFor, ttl: MusicTrendingSearches.usableFor, staleIfError: 86_400, retries: 0)
        do {
            let answer = try await MusicFetch.shared.value(MusicTrendingSearches.cacheKey(region: region), policy: policy, keep: { !$0.isEmpty }) {
                await Self.fetch(sources, region: region)
            }
            if Task.isCancelled || self.region != region { return }
            Self.memory[region] = (Date(), answer.value)
            phase = answer.value.isEmpty ? .empty : .loaded(answer.value)
            MusicDebugLog.log("search", "trending \(label): \(answer.value.count) chips, \(answer.source == .network ? "cache miss, asked sources" : "disk cache hit")")
        } catch {
            if Task.isCancelled { return }
            if case .loaded = phase {} else { phase = .empty }
            MusicDebugLog.log("search", "trending \(label): failed, \(error.localizedDescription)")
        }
    }

    /// The region's chart shelves, as Explore composes them, turned into chips. Each source has its own deadline; a source that misses it is left out.
    nonisolated private static func fetch(_ sources: [Source], region: String) async -> [MusicTrendingSearches.Chip] {
        let parts: [MusicExploreComposition.Part] = await withTaskGroup(of: (Int, MusicExploreComposition.Part?).self) { group in
            for (i, s) in sources.enumerated() {
                group.addTask {
                    let p = s.provider
                    let sections: [MusicBrowseSection]? = try? await MusicStreamResolver.withDeadline(MusicHomeLoaders.sourceDeadline) { () async throws -> [MusicBrowseSection] in
                        if let r = p as? any MusicRegionalDiscovery { return try await MusicDiscoveryFetch.regional(r, providerID: p.id, region: region) }
                        return try await MusicDiscoveryFetch.featured(p)
                    }
                    guard let sections else { return (i, nil) }
                    return (i, MusicExploreComposition.Part(providerID: p.id, regional: s.regional, sections: sections, followsRegion: s.follows))
                }
            }
            var got: [(Int, MusicExploreComposition.Part)] = []
            for await (i, part) in group { if let part { got.append((i, part)) } }
            return got.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let composed = MusicExploreComposition.compose(parts, region: region)
        // Only the country's own chart (and its new releases) speak for the country; the worldwide lists are used only when the person chose Worldwide.
        var shelves: [MusicBrowseSection] = []
        if let c = composed.charts { shelves.append(c) }
        if MusicDiscoveryRegion.isWorldwide(region) { shelves += composed.worldwide }
        if let r = composed.releases { shelves.append(r) }
        return MusicTrendingSearches.build(from: shelves)
    }
}

/// The Trending block: a title and chips with a small picture. A song or an unidentified name runs that search; an artist or album with an id opens it.
struct MusicTrendingBlock: View {
    let hub: MusicHub
    let model: MusicTrendingModel
    let search: (String) -> Void

    var body: some View {
        switch model.phase {
        case .loading:
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Trending"))
                MusicChipFlow(spacing: MusicSpace.xs) {
                    ForEach(0..<8, id: \.self) { i in MusicSkeletonBlock(width: CGFloat(96 + (i * 23) % 60), height: 32, corner: 16) }
                }
                .musicSkeletonShimmer().accessibilityElement().accessibilityLabel(Localized.string("Loading"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(let chips):
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Trending"))
                MusicChipFlow(spacing: MusicSpace.xs) {
                    ForEach(chips) { chip in MusicTrendingChip(chip: chip) { tap(chip) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Trending"))
                Text(verbatim: Localized.string("No trending searches for %@ yet", MusicDiscoveryRegion.name(model.region)))
                    .musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tap(_ chip: MusicTrendingSearches.Chip) {
        switch (chip.kind, chip.entityID, chip.providerID) {
        case (.artist, let id?, let pid?):
            MusicDebugLog.log("search", "trending tap artist \(chip.title): opens the artist")
            MusicEntityActions.open(.artist(MusicArtist(id: id, providerID: pid, name: chip.title, thumbnails: chip.thumbnails)), hub: hub)
        case (.album, let id?, let pid?):
            MusicDebugLog.log("search", "trending tap album \(chip.title): opens the album")
            let artists = chip.subtitle.isEmpty ? [] : [MusicArtistRef(id: "", name: chip.subtitle)]
            MusicEntityActions.open(.album(MusicAlbum(id: id, providerID: pid, title: chip.title, artists: artists, thumbnails: chip.thumbnails)), hub: hub)
        default:
            MusicDebugLog.log("search", "trending tap \(chip.kind.rawValue) \(chip.title): searches")
            search(chip.query)
        }
    }
}

/// One Trending chip: a 22 pt picture (round for an artist) when the chart item has art, and the name. The picture has its own fixed size and takes no clicks.
struct MusicTrendingChip: View {
    let chip: MusicTrendingSearches.Chip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.xs) {
                if !chip.thumbnails.isEmpty {
                    MusicCoverImage(thumbs: chip.thumbnails, artworkClass: chip.kind == .artist ? .artistPortrait : .trackThumb, size: 22, corner: chip.kind == .artist ? 11 : 4)
                        .frame(width: 22, height: 22).clipped().allowsHitTesting(false).accessibilityHidden(true)
                }
                Text(verbatim: chip.title).lineLimit(1).frame(maxWidth: 220)
            }
        }
        .musicButton(.chip, size: .compact)
        .musicTooltip(verbatim: chip.subtitle.isEmpty ? chip.title : chip.title + " · " + chip.subtitle)
        .accessibilityLabel(chip.subtitle.isEmpty ? chip.title : chip.title + ", " + chip.subtitle)
        .atlas("control.music.searchTrendingChip")
    }
}
