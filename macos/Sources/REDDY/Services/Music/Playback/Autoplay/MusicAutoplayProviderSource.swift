import Foundation

/// The provider's own radio (recommendations, then the artist's top tracks and related artists, then a search) as an autoplay source.
/// It is the fallback behind the graph source and works whenever the graph knows nothing about a song. Not part of the throwaway test
/// package (it needs the provider protocol); the selection rules it feeds are.
enum MusicAutoplayProviderSource {
    static func make(provider: any MusicMetadataProvider) -> MusicClosureAutoplaySource {
        MusicClosureAutoplaySource(name: "provider-radio") { request in
            var filter = MusicEndlessFilter()
            // The selector applies blocking, history, spacing and caps; this stage only widens the pool.
            filter.limit = 60
            filter.perArtistCap = 8
            filter.seedArtistCap = 12
            filter.seedArtistKeys = Set(MusicAutoplaySelector.artistKeys(request.seed))
            var seeds = [request.seed]
            for t in request.recentSeeds where seeds.count < MusicEndlessSource.maxSeeds { seeds.append(t) }
            let found = await MusicEndlessSource.load(provider: provider, current: request.seed, seeds: seeds, filter: filter)
            let seedArtists = Set(MusicAutoplaySelector.artistKeys(request.seed))
            let name = request.seed.artists.first?.name
            return found.enumerated().map { i, t in
                let same = !seedArtists.isDisjoint(with: MusicAutoplaySelector.artistKeys(t))
                return MusicAutoplayCandidate(track: t, reason: same ? MusicAutoplayReason(.artist, name) : MusicAutoplayReason(.radio, request.seed.title), rank: i)
            }
        }
    }
}
