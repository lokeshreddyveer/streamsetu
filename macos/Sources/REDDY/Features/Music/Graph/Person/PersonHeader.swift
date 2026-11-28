import SwiftUI

/// The top of a person page: portrait (or initials), name in both scripts, role chips that double as the role switcher, life dates, a short bio line
/// with its source, and Play, Shuffle, Follow and Start radio for the active role. Everything shown comes from the entity and its edges.
struct MusicPersonHeaderView: View {
    let hub: MusicHub
    let model: MusicPersonGraphModel
    let header: MusicPersonHeaderData
    let playback: MusicPersonPlayback
    /// What the active role lists, for the radio modes and the line of counts. Nil until the role's sections load.
    var catalog: MusicArtistCatalog? = nil
    /// Plays and likes on this Mac, for the radio modes that need them.
    var personal: MusicArtistPersonal = .empty

    /// What Wikipedia and Wikidata say about the person: the opening of the article, the native language, the portrait. Arrives after the page; the page is complete without it.
    @State private var wiki: MusicPersonWikiInfo?
    /// Genres, the years the person was active and the like from Wikidata; arrives after the page, which is complete without it.
    @State private var facts: MusicPersonFacts?
    @State private var bioOpen = false
    @State private var loadedFor: MusicEntityID?
    private var favorites: MusicFavoriteArtists { MusicFavoriteArtists.shared }

    private var subject: MusicArtworkSubject { MusicArtworkSubject(kind: header.isGroup ? .group : .person, name: header.names.display, id: header.id) }

    var body: some View {
        let source = MusicPersonPlaySource.choose(model.viewData)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicPageHeader(title: header.names.display, kind: MusicPersonWording.kindLabel(isGroup: header.isGroup, groupKind: header.groupKind, summary: model.roles),
                            subtitle: subtitle, thumbs: [], round: true, coverSize: 190, titleFont: Typography.display, customCover: AnyView(portrait), detail: AnyView(detail)) {
                actions(source)
            }
        }
        .task(id: "\(header.id.rawValue)|\(header.wikidataID ?? "")|\(header.tmdbPersonID ?? "")|\(model.activeView?.rawValue ?? "")") {
            // Only another person clears what is shown; switching the role view reloads in place, so the line and genres do not blink away and back.
            if MusicPersonHeaderLoadRules.clearsFacts(loadedFor: loadedFor, now: header.id) { facts = nil; wiki = nil }
            loadedFor = header.id
            // The favourites check reads the graph once per stored favourite: it runs on its own so the biography and facts never wait for it.
            Task { await favorites.adoptMerges(in: MusicGraphRuntime.shared.store) }
            if header.wikidataID?.isEmpty == false {
                async let w: Void = loadWiki()
                async let f: Void = loadFacts()
                _ = await (w, f)
            } else {
                await loadWiki(); await loadFacts()
            }
        }
    }

    // MARK: pieces

    private var portrait: some View {
        MusicCoverImage(thumbs: portraitURL.map { [MusicThumbnail(url: $0.absoluteString, width: 400, height: 400)] } ?? [], artworkClass: .artistPortrait, size: 190,
                        corner: 95, seed: header.names.display, initials: header.initials, subject: subject)
            .accessibilityHidden(true)
    }

    /// The person's own portrait from Wikidata when there is one: a provider's avatar (a channel picture, often a poster or a logo) never stands in for it.
    private var portraitURL: URL? {
        if let f = wiki?.portraitFile, header.portrait?.origin != .tmdb, let u = MusicPortraitRef.commonsThumbnailURL(file: f, width: 400) { return u }
        return header.portrait?.url
    }

    /// The name in the person's own script, now that the native language may be known.
    private var otherScript: String? {
        MusicPersonNames.resolve(snapshot: MusicEntitySnapshot.stub(name: header.names.display, lang: header.entityLanguage), aliases: header.aliases,
                                 languages: [wiki?.nativeLanguage].compactMap { $0 }).otherScript ?? header.names.otherScript
    }

    private var bioText: String? { wiki?.extract ?? wiki?.description.flatMap { $0.isEmpty ? nil : $0 } ?? header.bio?.text }

    /// The same name in the other script, then life dates: "राज कपूर · 1924–1988".
    private var subtitle: String {
        [otherScript, header.life.map(MusicPersonWording.life), header.disambiguator.flatMap { header.life == nil && header.bio == nil ? $0 : nil }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicPersonRoleChips(model: model)
            if let c = catalog {
                let line = MusicArtistWording.headerLine(MusicArtistStats(c), country: model.snapshot?.country, active: MusicPersonFactsRules.activeYears(facts))
                if !line.isEmpty { Text(verbatim: line).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            if let aka = MusicPersonAliasLine.line(aliases: header.aliases.map(\.text), display: header.names.display, otherScript: otherScript) {
                Text(verbatim: aka).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let g = facts?.genres, !g.isEmpty {
                Text(verbatim: g.prefix(4).joined(separator: " · ")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let text = bioText {
                // Four lines, then "More", the way the movie pages show a person's biography.
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: text).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(bioOpen ? nil : 4).fixedSize(horizontal: false, vertical: true)
                    if text.count > 240 {
                        Button(bioOpen ? Localized.string("Less") : Localized.string("More")) { bioOpen.toggle() }
                            .musicButton(.tertiary, size: .compact, accentText: true).atlasCovers("control.music.filmSynopsisMore")
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
        // The role chips and the biography arrive after the name; this block keeps its room from the start so the name and the buttons do not move when they do.
        .frame(minHeight: Self.detailMinHeight, alignment: .top)
    }

    static let detailMinHeight: CGFloat = 84

    fileprivate func loadWiki() async {
        guard let transport = MusicEntityArtwork.shared.transportIfAllowed() else { return }
        // A person with no Wikidata or TMDB link yet is looked up by name, strictly (a band by its own words, a person by the role the page shows).
        let lookup = MusicPersonWikiInfoLoader.Lookup(name: header.names.display, isGroup: header.isGroup, roleWords: MusicPersonWikiRules.roleWords(forView: model.activeView?.rawValue))
        let loaded = await MusicPersonWikiInfoLoader.shared.info(qid: header.wikidataID, tmdbID: header.tmdbPersonID, sitelinks: header.sitelinks, readingLanguages: MusicPersonNames.readerLanguages,
                                                          transport: transport, tmdb: MusicEntityArtwork.shared.tmdbFetch, lookup: lookup)
        // A slower, older lookup (a role switched away from) never overwrites the newer one.
        if !Task.isCancelled { wiki = loaded }
    }

    fileprivate func loadFacts() async {
        guard let transport = MusicEntityArtwork.shared.transportIfAllowed(), let qid = header.wikidataID ?? wiki?.qid, !qid.isEmpty else { return }
        let f = await MusicPersonFactsLoader.shared.facts(qid: qid, readingLanguages: MusicPersonNames.readerLanguages, transport: transport)
        if !Task.isCancelled { facts = f }
    }

    // MARK: actions

    @ViewBuilder private func actions(_ source: MusicPersonPlaySource) -> some View {
        let name = header.names.display
        Button { Task { await playback.play(source, shuffle: false) } } label: { Label(MusicPersonWording.play, systemImage: "play.fill") }
            .musicButton(.hero, size: .large).disabled(playback.busy).accessibilityLabel(MusicPersonWording.playLabel(name)).atlas("control.music.personPlay")
        Button { Task { await playback.play(source, shuffle: true) } } label: { Label(MusicPersonWording.shuffle, systemImage: "shuffle") }
            .musicButton(.secondary, size: .large).disabled(playback.busy).accessibilityLabel(MusicPersonWording.shuffleLabel(name)).atlas("control.music.personShuffle")
        if MusicPersonFollowRules.offersFollow(view: model.activeView), let artist = playback.followTarget(name: name, imageRef: model.snapshot?.imageRef) {
            let following = hub.library.isFollowing(artist)
            Button { MusicEntityActions.toggleFollow(artist, hub: hub) } label: { Text(verbatim: following ? MusicPersonWording.following : MusicPersonWording.follow) }
                .musicButton(.secondary, size: .large).accessibilityLabel(following ? Localized.string("Unfollow %1$@", name) : Localized.string("Follow %1$@", name)).atlas("control.music.personFollow")
        }
        // The Library's Favorite artists shelf is for artists you listen to: an actor or director view does not offer it, like Follow.
        if MusicPersonFollowRules.offersFollow(view: model.activeView) {
            let favorite = favorites.isFavorite(header.id)
            Button {
                favorites.toggle(header.id)
                MusicToasts.shared.show(favorite ? Localized.string("Removed from your favorite artists.") : Localized.string("Added to your favorite artists."))
            } label: { Label(favorite ? Localized.string("Favorited") : Localized.string("Favorite"), systemImage: favorite ? "heart.fill" : "heart") }
                .musicButton(.secondary, size: .large).accessibilityLabel(favorite ? Localized.string("Remove %1$@ from favorite artists", name) : Localized.string("Add %1$@ to favorite artists", name))
                .atlas("control.music.artistFavorite")
        }
        Button { Task { await playback.radio(source) } } label: { Label(MusicPersonWording.startRadio, systemImage: "dot.radiowaves.left.and.right") }
            .musicButton(.secondary, size: .large).disabled(playback.busy).accessibilityLabel(MusicPersonWording.startRadioFrom(name)).atlas("control.music.personRadio")
        radioModesMenu
        moreMenu(name)
    }

    // MARK: radio modes and More

    /// Artist essentials, deep cuts, the complete catalog, one language, one decade: each a bounded set of recordings (at most `MusicArtistPlayCap.songs`) that the player shuffles.
    @ViewBuilder private var radioModesMenu: some View {
        if let c = catalog {
            let options = MusicArtistRadioMode.options(c, personal: personal)
            if options.count > 1 {
                Menu {
                    ForEach(options, id: \.mode) { o in
                        Button(MusicArtistWording.radioTitle(o.mode) + " · \(o.count)") { startMode(o.mode, c) }.atlas("control.music.artistRadioMode")
                    }
                } label: { Label(Localized.string("Radio modes"), systemImage: "dot.radiowaves.left.and.right").musicChipSurface() }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(playback.busy).atlas("control.music.artistRadioModes")
            }
        }
    }

    private func startMode(_ mode: MusicArtistRadioMode, _ c: MusicArtistCatalog) {
        var g = SystemRandomNumberGenerator()
        let ids = MusicArtistRadioMode.ids(mode, in: c, personal: personal, using: &g)
        Task { await playback.playSet(ids, shuffle: true) }
    }

    @ViewBuilder private func moreMenu(_ name: String) -> some View {
        let top = catalog?.primarySongs ?? []
        let artist = MusicPersonFollowRules.offersFollow(view: model.activeView) ? playback.providerArtist.map { MusicArtistRef(id: $0.id, name: name) } : nil
        // An actor or director page is not the singer page of a namesake: only a view that offers Follow shares the provider artist's link.
        let providerLink = MusicPersonFollowRules.offersFollow(view: model.activeView) ? playback.followTarget(name: name, imageRef: model.snapshot?.imageRef).flatMap { MusicShare.link(for: $0) } : nil
        let link = MusicArtistShareLink.url(appLink: providerLink,
                                            sitelinks: header.sitelinks, wikidataID: header.wikidataID ?? wiki?.qid)
        if !top.isEmpty || artist != nil || link != nil {
            Menu {
                if !top.isEmpty {
                    Button(Localized.string("Play next")) { Task { await playback.queueSet(MusicArtistPlayCap.play(top, cap: MusicArtistPlayCap.queue), next: true) } }.atlas("control.music.artistPlayNext")
                    Button(Localized.string("Add to queue")) { Task { await playback.queueSet(MusicArtistPlayCap.play(top, cap: MusicArtistPlayCap.queue), next: false) } }.atlas("control.music.artistAddToQueue")
                }
                if !top.isEmpty {
                    Button(Localized.string("Create playlist")) {
                        Task { await playback.createPlaylist(name: Localized.string("%1$@: %2$@", name, MusicArtistWording.songsTitle(model.activeView ?? .singer)), ids: MusicArtistPlayCap.play(top)) }
                    }.atlas("control.music.artistCreatePlaylist")
                }
                if let link {
                    Button(Localized.string("Copy link")) { MusicShare.copy(link); MusicToasts.shared.show(Localized.string("Link copied.")) }.atlas("control.music.artistCopyLink")
                    #if os(macOS)
                    Button(Localized.string("Share…")) { MusicShare.showPicker(for: link) }.atlas("control.music.artistShare")
                    #endif
                }
                if let artist {
                    let hidden = MusicHiddenRecommendations.shared.isHidden(artist: artist)
                    Button(hidden ? Localized.string("Include in recommendations") : Localized.string("Exclude from recommendations")) {
                        if hidden { MusicHiddenRecommendations.shared.show(artist: artist); MusicToasts.shared.show(Localized.string("Included in recommendations again.")) }
                        else { MusicHiddenRecommendations.shared.hide(artist: artist); MusicToasts.shared.show(Localized.string("Excluded from recommendations.")) }
                    }.atlas("control.music.artistExclude")
                }
            } label: { Image(systemName: "ellipsis").accessibilityLabel(Localized.string("More")).musicChipSurface() }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().atlas("control.music.artistMore")
        }
    }
}

/// Role chips. With several roles they are the switcher (the chosen one is selected, and the choice is remembered for Back); with one they are plain
/// labels; roles with edges but no page of their own (a producer) are plain labels too. Never a chip for a role no edge backs.
struct MusicPersonRoleChips: View {
    let model: MusicPersonGraphModel

    var body: some View {
        let roles = model.roles
        if !roles.isEmpty {
            HStack(spacing: MusicSpace.xs) {
                ForEach(roles.views, id: \.view) { v in
                    let title = MusicPersonWording.roleLabel(v.label)
                    if roles.needsSwitcher {
                        MusicChip(title: title, selected: model.activeView == v.view) { model.select(v.view) }
                            .accessibilityLabel(MusicPersonWording.chipLabel(title, count: v.count)).atlas("control.music.personRole")
                    } else { plain(title) }
                }
                ForEach(roles.extras, id: \.label) { plain(MusicPersonWording.roleLabel($0.label)) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(MusicPersonWording.roleSwitcherLabel(model.header?.names.display ?? ""))
        }
    }

    private func plain(_ t: String) -> some View {
        Text(verbatim: t).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            .padding(.horizontal, MusicSpace.sm).padding(.vertical, MusicSpace.xxs)
            .background(ColorTokens.elevated, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.line))
    }
}

/// "Did you mean": shown only when two distinct people share this name AND the route came from a name search.
struct MusicPersonDidYouMean: View {
    let hub: MusicHub
    let candidates: [MusicPersonCandidate]

    var body: some View {
        if MusicPersonDisambiguation.shouldShowRow(candidates) {
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: MusicPersonWording.didYouMean).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).accessibilityAddTraits(.isHeader)
                HStack(spacing: MusicSpace.xs) {
                    ForEach(candidates) { c in
                        Button { hub.open(c.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: c.name).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                                if let l = c.line { Text(verbatim: l).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                            }
                            .padding(.horizontal, MusicSpace.sm).padding(.vertical, MusicSpace.xs).frame(minHeight: MusicTokens.hitTarget)
                            .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line))
                        }
                        .buttonStyle(.plain).hoverHighlight().accessibilityLabel([c.name, c.line].compactMap { $0 }.joined(separator: ", ")).atlas("control.music.personDidYouMean")
                    }
                }
            }
        }
    }
}

enum MusicPersonHeaderLoadRules {
    /// The header's Wikipedia and Wikidata lines are cleared only when the page is now about a different person than the one they were loaded for.
    static func clearsFacts(loadedFor: MusicEntityID?, now: MusicEntityID) -> Bool { loadedFor != nil && loadedFor != now }
}

enum MusicPersonFollowRules {
    /// Follow and "Exclude from recommendations" belong to a musical artist of a service. On the actor and director views the same person is shown as screen or
    /// crew credit, and those views offer neither (the singer or composer view of the same person still does).
    static func offersFollow(view: MusicPersonView?) -> Bool { view != .actor && view != .director }
}

enum MusicPersonAliasLine {
    static let maxNames = 3

    /// "Also known as A, B, C": the other names the graph holds, without the display name, the name shown in the subtitle or a spelling that differs only in case or
    /// accents. Nil when there is none.
    static func line(aliases: [String], display: String, otherScript: String?) -> String? {
        var seen = Set([fold(display)])
        if let o = otherScript { seen.insert(fold(o)) }
        var out: [String] = []
        for a in aliases {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(fold(t)).inserted else { continue }
            out.append(t)
            if out.count == maxNames { break }
        }
        return out.isEmpty ? nil : Localized.string("Also known as %1$@", out.joined(separator: ", "))
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
