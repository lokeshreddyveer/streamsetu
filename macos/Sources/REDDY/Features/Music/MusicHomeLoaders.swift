import Foundation

/// Everything Home fetches, as plain functions of Sendable values. Each source is asked on its own; one that fails or is slow never holds
/// back the others, and a source with nothing to say simply leaves no shelf.
enum MusicHomeLoaders {
    struct Outcome: Sendable { var sections: [MusicBrowseSection] = []; var failed = false }
    struct RegionalResult: Sendable { var sections: [MusicBrowseSection]; var healthy: Int; var failed: Int }

    /// The catalogue's verdict on a source's song shelves. A catalogue-only source shows a song only once a playable copy is verified; when
    /// nothing can verify (the catalogue is off), a `strict` source shows no songs at all, and any other keeps the shelves as they are.
    static func resolve(_ sections: [MusicBrowseSection], from provider: any MusicMetadataProvider, strict: Bool) async -> [MusicBrowseSection] {
        guard MusicSearchEnrichment.isCatalogueOnly(provider.capabilities) else { return sections }
        func hasSongs(_ s: MusicBrowseSection) -> Bool { s.items.contains { if case .track = $0 { true } else { false } } }
        let rt = MusicCatalogRuntime.shared
        guard rt.isEnabled, let m = rt.matcher else { return strict ? sections.filter { !hasSongs($0) } : sections }
        // Shelves are checked two at a time (one after another was slow; all at once is a burst of hundreds of matches that starves the interface), and the
        // order of the shelves is kept.
        return await withTaskGroup(of: (Int, MusicBrowseSection?).self) { group in
            var next = 0, running = 0
            var done: [(Int, MusicBrowseSection)] = []
            func start() {
                guard next < sections.count else { return }
                let i = next, s = sections[i]
                next += 1; running += 1
                group.addTask(priority: .utility) { hasSongs(s) ? (i, await m.resolveShelf(s)) : (i, s) }
            }
            for _ in 0..<2 { start() }
            while running > 0, let (i, r) = await group.next() {
                running -= 1
                if let r { done.append((i, r)) }
                start()
            }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: language cut

    /// Keeps the songs and albums whose writing system is the language; a shelf left empty is dropped. Latin or no language cuts nothing.
    static func cut(_ s: MusicBrowseSection, to language: MusicLanguage?) -> MusicBrowseSection? {
        guard let language, language.script != .latin else { return s }
        let script = language.script
        let kept = s.items.filter { item in
            switch item {
            case .track(let t): return MusicLanguageDetector.language(of: t) == script
            case .album(let a): return MusicLanguageDetector.language(of: ([a.title] + a.artists.map(\.name)).joined(separator: " ")) == script
            default: return false
            }
        }
        guard !kept.isEmpty else { return nil }
        var out = s; out.items = kept
        return out
    }

    // MARK: the regional block

    /// No source gets longer than this: a slow one is given up on, and its shelves are simply not there this time.
    static let sourceDeadline: TimeInterval = 8
    /// A source that missed the first deadline is asked once more: its request is still running (or already saved) in the shared fetch layer, so the
    /// second ask joins it instead of starting over. Only a source that misses both counts as failed. A new country's first request is the slow one.
    static let secondChance: TimeInterval = 14

    static func withSecondChance(_ work: @escaping @Sendable () async -> Outcome) async -> Outcome {
        for limit in [sourceDeadline, secondChance] {
            if Task.isCancelled { return Outcome() }
            if let o = try? await MusicStreamResolver.withDeadline(limit, work), !o.failed { return o }
            else if limit == secondChance { break }
        }
        return Task.isCancelled ? Outcome() : Outcome(failed: true)
    }

    /// `onPartial` is told after every source that answers, with everything gathered so far (the page shows it at once); the return value is the final result.
    static func regional(key: MusicHomeKey, active: (any MusicMetadataProvider)?, discovery: [any MusicMetadataProvider], jioAlbums: Bool,
                         onPartial: (@MainActor @Sendable (RegionalResult) -> Void)? = nil) async -> RegionalResult {
        let region = key.region, language = key.language
        let asked: [MusicLanguage] = language.map { [$0] } ?? key.wanted
        let askJio = language?.jioSaavnCode != nil
        return await withTaskGroup(of: Outcome.self) { group in
            if region.isEmpty {
                // Worldwide: each source's own lists that are not about a country (Deezer's chart, Audius trending, ListenBrainz new releases).
                for p in discovery where !(p is any MusicLanguageDiscovery) {
                    group.addTask { await withSecondChance { await fromGlobal(p) } }
                }
            }
            for p in discovery where MusicRegionalSources.followsRegion(providerID: p.id, region: region) || (p.id == JioSaavnDiscoveryProvider.id && askJio && !region.isEmpty) {
                group.addTask { await withSecondChance { await fromDiscovery(p, region: region, language: language, asked: asked, jioAlbums: jioAlbums) } }
            }
            if let yt = active as? YouTubeMusicFullProvider, let cc = MusicRegionalSources.youTubeChartsCountry(for: region) {
                group.addTask { await withSecondChance { await fromYouTube(yt, country: cc, region: region, language: language) } }
            }
            var all: [MusicBrowseSection] = []
            var healthy = 0, failed = 0
            for await o in group {
                if o.failed { failed += 1 } else { healthy += 1 }
                all += o.sections
                if let onPartial {
                    let so_far = RegionalResult(sections: MusicHomeRegionalOrder.ordered(all, region: region), healthy: healthy, failed: failed)
                    await MainActor.run { onPartial(so_far) }
                }
            }
            return RegionalResult(sections: MusicHomeRegionalOrder.ordered(all, region: region), healthy: healthy, failed: failed)
        }
    }

    private static func fromGlobal(_ p: any MusicMetadataProvider) async -> Outcome {
        do { return Outcome(sections: try await MusicDiscoveryFetch.featured(p).filter { $0.scope == .global }) }
        catch {
            if error is CancellationError || (error as? MusicError) == .cancelled { return Outcome() }
            return (error as? MusicError) == .notFound ? Outcome() : Outcome(failed: true)
        }
    }

    private static func fromDiscovery(_ p: any MusicMetadataProvider, region: String, language: MusicLanguage?, asked: [MusicLanguage], jioAlbums: Bool) async -> Outcome {
        do {
            var raw: [MusicBrowseSection]
            let isJio = p.id == JioSaavnDiscoveryProvider.id
            if isJio {
                guard let j = p as? any MusicLanguageDiscovery else { return Outcome() }
                raw = try await MusicDiscoveryFetch.languages(j, providerID: p.id, region: region, languages: asked)
                if !jioAlbums { raw.removeAll { $0.id.hasPrefix("jiosaavn-albums-") } }
            } else {
                guard let r = p as? any MusicRegionalDiscovery else { return Outcome() }
                raw = try await MusicDiscoveryFetch.regional(r, providerID: p.id, region: region)
                // A country's own chart is shown as the service gives it: cutting it by the writing system of each title removed the whole chart for any country whose
                // songs are in Latin letters, so choosing a country changed nothing. The language chip adds language shelves; it never removes the country's.
            }
            // A source that substituted its worldwide list for a country it has no chart for is not the country's: that list is left out of this block.
            let resolved = await resolve(raw.filter { $0.scope != .global }, from: p, strict: isJio)
            return Outcome(sections: resolved.map { retitled($0, region: region, language: language) })
        } catch {
            if error is CancellationError || (error as? MusicError) == .cancelled { return Outcome() }
            // A source that has nothing for this country says so with "not found"; that is not a failure.
            return (error as? MusicError) == .notFound ? Outcome() : Outcome(failed: true)
        }
    }

    /// Apple's shelves are titled in English by the provider; here they get the app's wording, with the country (and language) named.
    static func retitled(_ s: MusicBrowseSection, region: String, language: MusicLanguage?) -> MusicBrowseSection {
        var out = s
        if s.id.hasPrefix("itunes-songs-") { out.title = MusicRegionalSources.topSongsTitle(region: region, language: nil) }   // the country's own chart is not cut by language, so its title never claims one
        else if s.id.hasPrefix("itunes-albums-") {
            let name = MusicDiscoveryRegion.name(region)
            out.title = Localized.string("Top albums in %@", name)
        }
        return out
    }

    private static func fromYouTube(_ yt: YouTubeMusicFullProvider, country: String, region: String, language: MusicLanguage?) async -> Outcome {
        do {
            let shelves = try await yt.chartsPage(country: country)
            let name = MusicDiscoveryRegion.name(region)
            var out: [MusicBrowseSection] = []
            for s in shelves {
                guard let t = MusicHomeRegionalOrder.youTubeChartTitle(s.title, country: name, languageName: language?.displayName) else { continue }
                var items = s.items
                if let language, t.id == "ytm-chart-language" {
                    items = items.filter { if case .playlist(let p) = $0 { p.name.localizedCaseInsensitiveContains(language.englishName) } else { false } }
                }
                guard !items.isEmpty else { continue }
                out.append(MusicBrowseSection(id: t.id, title: t.title, items: Array(items.prefix(25)), scope: .regional(region.lowercased())))
            }
            return Outcome(sections: out)
        } catch {
            return error is CancellationError ? Outcome() : Outcome(failed: true)
        }
    }

    // MARK: "Because you listen to ..."

    /// One shelf for the language that leads the person's own plays, from a source that really has lists in that language. Nil when no source does.
    static func languageShelf(_ language: MusicLanguage, discovery: [any MusicMetadataProvider]) async -> MusicBrowseSection? {
        let title = Localized.string("Because you listen to %@", language.displayName)
        if language.jioSaavnCode != nil, let jio = discovery.first(where: { $0.id == JioSaavnDiscoveryProvider.id }), let j = jio as? any MusicLanguageDiscovery {
            guard let all = try? await MusicDiscoveryFetch.languages(j, providerID: jio.id, region: "in", languages: [language]),
                  let top = all.first(where: { $0.id == "jiosaavn-top-\(language.rawValue)" }) else { return nil }
            guard let shown = await resolve([top], from: jio, strict: true).first else { return nil }
            return MusicBrowseSection(id: "language-" + language.rawValue, title: title, items: shown.items)
        }
        if let cc = language.chartCountry, let apple = discovery.first(where: { $0.id == ITunesChartsDiscoveryProvider.id }), let r = apple as? any MusicRegionalDiscovery {
            guard let all = try? await MusicDiscoveryFetch.regional(r, providerID: apple.id, region: cc),
                  let songs = all.first(where: { $0.id.hasPrefix("itunes-songs-") }), let cutShelf = cut(songs, to: language),
                  let shown = await resolve([cutShelf], from: apple, strict: false).first else { return nil }
            return MusicBrowseSection(id: "language-" + language.rawValue, title: title, items: shown.items)
        }
        return nil
    }

    /// The other discovery sources (those that do not follow the country): each is asked on its own.
    static func discovery(_ p: any MusicMetadataProvider) async -> [MusicBrowseSection]? {
        do { return await resolve(try await MusicDiscoveryFetch.featured(p), from: p, strict: false) } catch { return nil }
    }

    // MARK: covers to warm

    static func addresses(_ s: MusicBrowseSection, pixels: Int) -> [String] {
        s.items.compactMap { item -> String? in
            let thumbs: [MusicThumbnail]
            switch item {
            case .track(let t): thumbs = t.thumbnails
            case .album(let a): thumbs = a.thumbnails
            case .artist(let a): thumbs = a.thumbnails
            case .playlist(let p): thumbs = p.thumbnails
            }
            return MusicArtworkService.pickThumbnail(thumbs, neededPixels: pixels)
        }
    }
}
