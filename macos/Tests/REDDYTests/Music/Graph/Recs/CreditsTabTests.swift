import Foundation
import Testing
@testable import REDDY

@Suite("Credits tab") struct CreditsTabTests {
    /// Awaara Hoon with its own singer and lyricist, an album whose music director is on the album, and a film linked only by inference.
    private func world(filmVerified: Bool = false) async -> (w: RecWorld, song: MusicEntityID, album: MusicEntityID, film: MusicEntityID, sj: MusicEntityID, shailendra: MusicEntityID, mukesh: MusicEntityID) {
        let w = RecWorld()
        let sj = await w.ent(.person, "Shankar-Jaikishan", year: 1922), shailendra = await w.ent(.person, "Shailendra", year: 1923), mukesh = await w.ent(.person, "Mukesh", year: 1923)
        let rk = await w.ent(.person, "Raj Kapoor", year: 1924)
        let film = await w.ent(.film, "Awaara", lang: "hi", year: 1951)
        let album = await w.ent(.album, "Awaara (Original Motion Picture Soundtrack)", lang: "hi", year: 1951)
        await w.link(album, .soundtrackOf, film, verified: filmVerified)
        await w.link(album, .musicDirectedBy, sj, role: .musicDirector, level: .album)
        await w.link(film, .musicDirectedBy, sj, role: .musicDirector, level: .film)
        await w.link(film, .producedBy, rk, role: .producer, level: .film)
        let song = await w.song("Awaara Hoon", year: 1951, lang: "hi", album: album, order: 1, lyricist: shailendra, singers: [mukesh])
        return (w, song, album, film, sj, shailendra, mukesh)
    }

    private func run(_ w: RecWorld, _ song: MusicEntityID) async throws -> (partials: [MusicSectionResult], final: MusicSectionResult) {
        let log = PartialLog()
        let final = try await MusicSongCreditsLoader().load(entity: song, store: w.g, report: log.reporter)
        return (log.results, final)
    }

    @Test func rolesAreGroupedAndNamesLinkToPeopleOnTheirRole() async throws {
        let x = await world()
        let (_, final) = try await run(x.w, x.song)
        let items = final.items.compactMap { $0.base as? MusicSongCreditItem }
        let layout = MusicCreditsLayout.make(items: items, phase: .loaded)
        #expect(layout.songTitle == "Awaara Hoon" && layout.version == nil)
        // Fixed heading order, only headings with people.
        // The song's own groups hold only the song's own credits; the album's and the film's credits sit apart.
        #expect(layout.groups.map(\.group) == [.singers, .lyricists])
        let singers = try #require(layout.groups.first { $0.group == .singers })
        #expect(singers.rows.map(\.name) == ["Mukesh"] && singers.rows[0].person == x.mukesh && singers.rows[0].linkRole == .singer && !singers.rows[0].inherited)
        let lyr = try #require(layout.groups.first { $0.group == .lyricists })
        #expect(lyr.rows[0].person == x.shailendra && lyr.rows[0].linkRole == .lyricist)
        // The music director comes from the album and the film, once, kept in the album's own part (the closer level) and never in the song's groups.
        let md = try #require(layout.fromAlbum.first { $0.group == .musicDirectors })
        #expect(md.rows.count == 1 && md.rows[0].person == x.sj && md.rows[0].linkRole == .musicDirector && md.rows[0].inherited)
        #expect(md.rows[0].level == .album)
        #expect(layout.fromFilm.first { $0.group == .producers }?.rows.first?.name == "Raj Kapoor")
        #expect(layout.groups.first { $0.group == .musicDirectors } == nil && layout.groups.first { $0.group == .producers } == nil)
        // Film and album links go to their own pages.
        #expect(layout.album?.id == x.album && layout.film?.id == x.film && layout.film?.year == 1951)
        // The film link rests on a provider's wording through the album: flagged inferred.
        #expect(layout.film?.inferred == true && layout.album?.inferred == false)
        #expect(!layout.showsEmptyLine && layout.hasPeople)
    }

    @Test func aVerifiedFilmLinkIsNotMarkedInferred() async throws {
        let x = await world(filmVerified: true)
        let (_, final) = try await run(x.w, x.song)
        let layout = MusicCreditsLayout.make(items: final.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded)
        #expect(layout.film?.inferred == false)
    }

    @Test func partialResultsComeFirstAndTheFinalOneAddsAlbumAndFilmCredits() async throws {
        let x = await world()
        let (partials, final) = try await run(x.w, x.song)
        #expect(partials.count == 1)
        let first = MusicCreditsLayout.make(items: partials[0].items.compactMap { $0.base as? MusicSongCreditItem }, phase: .partial)
        // First paint: the song's own people and its album, no music director yet, no empty line while it is still arriving.
        #expect(first.groups.map(\.group) == [.singers, .lyricists])
        #expect(first.album?.id == x.album && first.film == nil && !first.showsEmptyLine)
        let last = MusicCreditsLayout.make(items: final.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded)
        #expect(first.fromAlbum.isEmpty && first.fromFilm.isEmpty)
        #expect(!last.fromAlbum.isEmpty && !last.fromFilm.isEmpty && last.film != nil)
        // What was shown first stays where it was (same people, same order) once more arrives.
        #expect(last.groups.first { $0.group == .singers }?.rows == first.groups.first { $0.group == .singers }?.rows)
    }

    @Test func theSongsOwnCreditBeatsTheSamePersonFromTheAlbum() async throws {
        let x = await world()
        await x.w.link(x.song, .musicDirectedBy, x.sj, role: .musicDirector, level: .song)
        let (_, final) = try await run(x.w, x.song)
        let layout = MusicCreditsLayout.make(items: final.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded)
        let md = try #require(layout.groups.first { $0.group == .musicDirectors })
        #expect(md.rows.count == 1 && !md.rows[0].inherited && md.rows[0].level == .song)
    }

    @Test func sourcesAreNamedMostTrustedFirst() async throws {
        let x = await world()
        // The singer is also claimed by a provider; MusicBrainz outranks it.
        _ = try await x.w.g.addEdge(MusicEdge(subject: x.song, predicate: .performedBy, object: x.mukesh, role: .singer, creditLevel: .song), provenance: RecWorld.inferredClaim)
        let (_, final) = try await run(x.w, x.song)
        let layout = MusicCreditsLayout.make(items: final.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded)
        #expect(layout.sources.first == "MusicBrainz")
        let singer = layout.groups.first { $0.group == .singers }!.rows[0]
        #expect(singer.sources == ["MusicBrainz", "JioSaavn"])
        #expect(final.provenance.map(\.source?.rawValue).contains("musicbrainz"))
    }

    @Test func theEmptyLineAppearsOnlyWhenFinishedAndNobodyIsCredited() async throws {
        let w = RecWorld()
        let bare = await w.ent(.recording, "Untitled Demo")
        let (partials, final) = try await run(w, bare)
        #expect(partials.count == 1)
        let items = final.items.compactMap { $0.base as? MusicSongCreditItem }
        for (phase, shows) in [(MusicSectionPhase.idle, false), (.loading, false), (.partial, false), (.failed, false), (.loaded, true), (.empty, true)] {
            #expect(MusicCreditsLayout.make(items: items, phase: phase).showsEmptyLine == shows, "\(phase)")
        }
        // As soon as one person is credited the line is gone, in any phase.
        let sj = await w.ent(.person, "Someone")
        await w.link(bare, .performedBy, sj, role: .performer)
        let (_, again) = try await run(w, bare)
        #expect(!MusicCreditsLayout.make(items: again.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded).showsEmptyLine)
        // An unknown entity gives an empty section, never a crash.
        let ghost = MusicEntityID.derive(kind: .recording, aliasKey: "nobody")
        let (_, none) = try await run(w, ghost)
        #expect(none.items.isEmpty)
    }

    @Test func peopleWithOneNameStaySeparateAndGetAHint() async throws {
        let w = RecWorld()
        let a = await w.ent(.person, "Anand Bakshi", year: 1930, uid: "mb:ab1"), b = await w.ent(.person, "Anand Bakshi", year: 1962, uid: "mb:ab2")
        let song = await w.song("Two Writers", year: 1975, lang: "hi", lyricist: a)
        await w.link(song, .writtenBy, b, role: .lyricist)
        let (_, final) = try await run(w, song)
        let layout = MusicCreditsLayout.make(items: final.items.compactMap { $0.base as? MusicSongCreditItem }, phase: .loaded)
        let rows = try #require(layout.groups.first { $0.group == .lyricists }).rows
        #expect(rows.count == 2 && Set(rows.map(\.person)) == [a, b])
        #expect(Set(rows.compactMap(\.hint)) == ["b. 1930", "b. 1962"])
        // A name that is not shared carries no hint.
        let one = MusicCreditsLayout.make(items: [.credit(MusicCreditEntry(person: a, name: "Anand Bakshi", role: .lyricist, level: .song, inherited: false, sources: [], order: 0, hint: "b. 1930"))], phase: .loaded)
        #expect(one.groups[0].rows[0].hint == nil)
    }

    @Test func aPersonWithTwoRolesInOneGroupIsOneRowAndSeveralRolesAcrossGroupsAreSeveralRows() async throws {
        let p = MusicEntityID.derive(kind: .person, aliasKey: "p")
        func entry(_ r: MusicRole, order: Int = 0) -> MusicSongCreditItem {
            .credit(MusicCreditEntry(person: p, name: "Ilaiyaraaja", role: r, level: .song, inherited: false, sources: ["MusicBrainz"], order: order, hint: nil))
        }
        let layout = MusicCreditsLayout.make(items: [entry(.composer), entry(.arranger), entry(.singer), entry(.lyricist), entry(.instrumentalist)], phase: .loaded)
        #expect(layout.groups.map(\.group) == [.singers, .composers, .lyricists, .other])
        let composers = layout.groups.first { $0.group == .composers }!.rows
        #expect(composers.count == 1 && composers[0].roles == [.arranger, .composer] || composers[0].roles == [.composer, .arranger])
        #expect(composers[0].linkRole == composers[0].roles[0])
        #expect(MusicCreditGroup.group(for: .musicDirector) == .musicDirectors && MusicCreditGroup.group(for: .producer) == .producers && MusicCreditGroup.group(for: .actor) == .other)
        // Every role lands in some group, and the headings are fixed.
        for r in MusicRole.allCases { #expect(MusicCreditGroup.allCases.contains(MusicCreditGroup.group(for: r))) }
        #expect(MusicCreditGroup.allCases.map(\.title) == ["Singers", "Composers", "Lyricists", "Music directors", "Producers", "Other contributors"])
    }

    @Test func versionOfTheSongShowsAndOriginalDoesNot() async throws {
        let w = RecWorld()
        let remix = await w.ent(.recording, "Awaara Hoon (Remix)", attrs: ["versionKind": "remix"])
        let orig = await w.ent(.recording, "Awaara Hoon", attrs: ["versionKind": "original"])
        let r1 = try await run(w, remix).final.items.compactMap { $0.base as? MusicSongCreditItem }
        let r2 = try await run(w, orig).final.items.compactMap { $0.base as? MusicSongCreditItem }
        #expect(MusicCreditsLayout.make(items: r1, phase: .loaded).version == .remix)
        #expect(MusicCreditsLayout.make(items: r2, phase: .loaded).version == nil)
    }

    @MainActor @Test func theTabWorksOfflineFromTheGraphAndStaysStableThroughTheSharedModel() async throws {
        let x = await world()
        let center = MusicEntityModelCenter(store: MusicEntityStore(graph: x.w.g))
        let a = center.acquire(x.song), b = center.acquire(x.song)
        let key = MusicSongCreditsLoader.sectionKey
        a.model.load(MusicSongCreditsLoader()); b.model.load(MusicSongCreditsLoader())
        for _ in 0..<300 { if a.model.section(key).phase == .loaded { break }; try? await Task.sleep(for: .milliseconds(10)) }
        let s = a.model.section(key)
        let layout = MusicCreditsLayout.make(items: s.items(MusicSongCreditItem.self), phase: s.phase)
        #expect(s.phase == .loaded && layout.hasPeople && layout.film?.id == x.film)
        #expect(a.model === b.model && a.model.sectionRuns[key] == 1, "two views of the same song share one load")
        // Leaving and coming back inside the grace window keeps the loaded section (no new run).
        a.release(); b.release()
        let again = center.acquire(x.song)
        again.model.load(MusicSongCreditsLoader())
        #expect(again.model.sectionRuns[key] == 1 && again.model.section(key).phase == .loaded)
        again.release()
    }
}
