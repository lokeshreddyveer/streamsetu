import Foundation
import Testing
@testable import REDDY

@Suite struct PersonReaderTests {
    private func build(_ w: PersonWorld, _ person: MusicEntityID, _ view: MusicPersonView, store: (any MusicGraphStoring)? = nil, maxReads: Int = MusicPersonReader.defaultMaxReads) async throws -> MusicPersonViewData {
        try await MusicPersonReader(store: store ?? w.store, person: person, maxReads: maxReads).build(view)
    }
    private func names(_ d: MusicPersonViewData, _ id: MusicPersonSectionID) -> [String] { d.section(id)?.entries.map(\.name) ?? [] }

    // MARK: singer

    @Test func mukeshSingerSections() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.mukesh, .singer)
        #expect(d.complete)
        // ranked by the source's popularity first
        #expect(names(d, .topSongs) == ["Awaara Hoon", "Mera Joota Hai Japani", "Pyar Hua Ikrar Hua", "Dum Dum Diga Diga", "Ek Do Teen"])
        #expect(Set(names(d, .albums)) == ["Awaara (Original Motion Picture Soundtrack)", "Shree 420", "Mukesh Sings"])
        #expect(d.section(.singles) == nil)   // no singles: no empty heading
        // film songs: grouped by film link; Awaara is stated (verified), Shree 420 is only inferred below 0.75 and is worded as possible
        let film = d.section(.filmSongs)?.entries ?? []
        #expect(film.map(\.name) == ["Mera Joota Hai Japani", "Pyar Hua Ikrar Hua", "Awaara Hoon"])
        #expect(film.first { $0.name == "Awaara Hoon" }?.reason == .fromFilm("Awaara"))
        #expect(film.first { $0.name == "Mera Joota Hai Japani" }?.reason == .possibleFilmLink("Shree 420"))
        #expect(d.section(.topSongs)?.entries.first?.filmTitle == "Awaara")
        // people
        #expect(names(d, .composersWorkedWith) == ["Shankar-Jaikishan", "Ravi"])
        #expect(d.section(.composersWorkedWith)?.entries.first?.count == 3)
        #expect(names(d, .collaborations) == ["Lata Mangeshkar"] && d.section(.collaborations)?.entries.first?.count == 2)
        #expect(Set(names(d, .languages)).count == 2 && d.section(.languages)?.entries.allSatisfy { !$0.navigable } == true)
        #expect(names(d, .playlists) == ["Golden Hindi"] && d.section(.playlists)?.entries.first?.count == 2)
        #expect(d.section(.radio)?.entries.first?.name == "Awaara Hoon")
        // never actor sections on a singer
        #expect(d.section(.filmography) == nil)
    }

    @Test func relatedArtistsComeFromSharedComposers() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.mukesh, .singer)
        // Lata sang three songs for his top two composers (gharAaya, pyar, duet); Kishore only one, below the two-song floor
        #expect(names(d, .relatedArtists) == ["Lata Mangeshkar"])
        #expect(d.section(.relatedArtists)?.entries.first?.reason == .sharedComposers(3))
    }

    @Test func partialReportsArriveInStagesAndCompleteLast() async throws {
        let w = try await PersonWorld.make()
        let seen = PersonBox<[Int]>([]), complete = PersonBox<[Bool]>([])
        let reader = MusicPersonReader(store: w.store, person: w.mukesh)
        let final = try await reader.build(.singer) { partial in seen.append(partial.sections.count); complete.append(partial.complete) }
        let counts = seen.value
        #expect(counts.count >= 3 && counts == counts.sorted() && counts.first! >= 1)
        #expect(complete.value.allSatisfy { !$0 } && final.complete)
    }

    @Test func cancellationStopsTheBuild() async throws {
        let w = try await PersonWorld.make()
        let task = Task { try await MusicPersonReader(store: w.store, person: w.mukesh).build(.singer) { _ in try? await Task.sleep(for: .seconds(5)) } }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let r = await task.result
        if case .success = r { Issue.record("expected cancellation") }
    }

    // MARK: composer, group

    @Test func shankarJaikishanGroupComposerPage() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.sj, .composer)
        #expect(Set(names(d, .popularCompositions)) == ["Awaara Hoon", "Ghar Aaya Mera Pardesi", "Mera Joota Hai Japani", "Pyar Hua Ikrar Hua", "Ek Ladki Bheegi Bhaagi Si"])
        #expect(names(d, .soundtracks).contains("Awaara (Original Motion Picture Soundtrack)") && names(d, .soundtracks).contains("Shree 420"))
        #expect(Set(names(d, .films)).isSuperset(of: ["Awaara", "Shree 420", "Barsaat"]))
        #expect(names(d, .singersWorkedWith).first == "Mukesh" && d.section(.singersWorkedWith)?.entries.first?.count == 3)
        #expect(Set(names(d, .lyricistsWorkedWith)) == ["Shailendra"])
        #expect(d.section(.filmography) == nil && d.section(.topSongs) == nil)
    }

    @Test func groupMembersOnlyWhenASourceListsThem() async throws {
        let w = try await PersonWorld.make()
        let members = await MusicPersonReader(store: w.store, person: w.sj).membersOfGroup()
        #expect(members.map(\.name) == ["Jaikishan", "Shankar"])
        // a duo with no member edges lists nobody (no invented members)
        let lonely = try await w.store.upsert(MusicEntityDraft(kind: .group, name: "Unlisted Duo", subkind: "duo", externalIDs: [ExternalID(.wikidata, "Q777")])).id
        #expect(await MusicPersonReader(store: w.store, person: lonely).membersOfGroup().isEmpty)
        // the person page says which group a member belongs to; it does not copy the group's credits
        let groups = await MusicPersonReader(store: w.store, person: w.shankar).groupsOfPerson()
        #expect(groups.map(\.name) == ["Shankar-Jaikishan"])
        #expect(try await MusicPersonRoles.summarize(incoming: w.store.edges(of: w.shankar, predicate: nil, direction: .incoming, limit: 100)).isEmpty)
    }

    @Test func composerWithSoundtracksOnly() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.ravi, .composer)
        // Ravi has a film credit, an album credit and ONE song credit (the duet); drop that song to model "soundtracks only"
        let only = try await PersonWorld.person(w.store, "Soundtrack Only", wikidata: "Q555")
        let film = try await PersonWorld.node(w.store, .film, "Silent Film", key: "tmdb:s1", year: 1962)
        let album = try await PersonWorld.node(w.store, .album, "Silent Film OST", key: "jiosaavn:s1", subkind: "soundtrack", year: 1962)
        try await w.add(film, .musicDirectedBy, only, role: .musicDirector, level: .film)
        try await w.add(album, .musicDirectedBy, only, role: .musicDirector, level: .album)
        try await w.add(album, .soundtrackOf, film, level: .film, by: PersonWorld.matcher)
        let o = try await build(w, only, .composer)
        #expect(names(o, .soundtracks) == ["Silent Film OST"] && names(o, .films) == ["Silent Film"])
        #expect(o.section(.popularCompositions) == nil && o.section(.singersWorkedWith) == nil && o.section(.lyricistsWorkedWith) == nil && o.section(.relatedComposers) == nil)
        #expect(o.section(.soundtracks)?.entries.first?.reason == .possibleFilmLink("Silent Film"))
        #expect(!d.isEmpty)
    }

    // MARK: lyricist

    @Test func shailendraLyricistSections() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.shailendra, .lyricist)
        #expect(Set(names(d, .songsWritten)) == ["Awaara Hoon", "Ghar Aaya Mera Pardesi", "Mera Joota Hai Japani", "Pyar Hua Ikrar Hua", "Ek Do Teen"])
        #expect(d.section(.songsWritten)?.entries.first { $0.name == "Awaara Hoon" }?.detail == "Mukesh")
        #expect(d.section(.songsWritten)?.entries.first { $0.name == "Pyar Hua Ikrar Hua" }?.detail == "Lata Mangeshkar, Mukesh")
        #expect(names(d, .composers).first == "Shankar-Jaikishan")
        #expect(Set(names(d, .singers)) == ["Mukesh", "Lata Mangeshkar"])
        #expect(names(d, .films).contains("Awaara"))
        #expect(names(d, .frequentCollaborators).contains("Shankar-Jaikishan") && names(d, .frequentCollaborators).contains("Mukesh"))
        #expect(d.section(.topSongs) == nil && d.section(.filmography) == nil)
    }

    @Test func sameNameLyricistKeepsOnlyHisOwnCredits() async throws {
        let w = try await PersonWorld.make()
        let a = try await build(w, w.bakshiA, .lyricist), b = MusicPersonRoles.summarize(incoming: try await w.store.edges(of: w.bakshiB, predicate: nil, direction: .incoming, limit: 100))
        #expect(names(a, .songsWritten) == ["Ek Do Teen"])
        #expect(b.isEmpty)
    }

    // MARK: actor and director

    @Test func rajKapoorActorSections() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.raj, .actor)
        #expect(names(d, .filmography) == ["Shree 420", "Awaara", "Barsaat", "Aag"])
        #expect(d.section(.filmography)?.entries.first { $0.name == "Awaara" }?.detail == "Raju")
        #expect(d.section(.popularMovies) == nil)   // four films: the shelf would only repeat the grid
        #expect(Set(names(d, .movieSoundtracks)) == ["Awaara (Original Motion Picture Soundtrack)", "Shree 420"])
        #expect(Set(names(d, .songsFromMovies)) == ["Awaara Hoon", "Ghar Aaya Mera Pardesi", "Mera Joota Hai Japani", "Pyar Hua Ikrar Hua"])
        #expect(d.section(.songsFromMovies)?.entries.first?.filmTitle != nil)
        #expect(names(d, .coStars) == ["Nargis"] && d.section(.coStars)?.entries.first?.count == 3 && d.section(.coStars)?.entries.first?.reason == .sharedFilms(3))
        #expect(d.section(.directorsWorkedWith) == nil)   // he directed his own films: nobody else to list
        // an actor page never lists his songs as "top songs" and carries no singer sections
        #expect(d.section(.topSongs) == nil && d.section(.composersWorkedWith) == nil)
    }

    @Test func rajKapoorDirectorSections() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.raj, .director)
        #expect(names(d, .filmography) == ["Shree 420", "Awaara", "Barsaat", "Aag"])
        #expect(Set(names(d, .filmSoundtracks)) == ["Awaara (Original Motion Picture Soundtrack)", "Shree 420"])
        #expect(names(d, .composersCollaborated) == ["Shankar-Jaikishan"] && d.section(.composersCollaborated)?.entries.first?.count == 3)
        #expect(names(d, .frequentCast) == ["Nargis"] && d.section(.frequentCast)?.entries.first?.count == 3)
        #expect(d.section(.coStars) == nil)
    }

    @Test func actorWithFilmsButNoSoundtracks() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.pran, .actor)
        #expect(Set(names(d, .filmography)) == ["Zanjeer", "Madhumati"])
        #expect(d.section(.movieSoundtracks) == nil && d.section(.songsFromMovies) == nil && d.section(.popularMovies) == nil)
        #expect(d.visible.map(\.id) == [.filmography])
    }

    @Test func personWhoIsActorAndSingerGetsEachViewFromItsOwnEdges() async throws {
        let w = try await PersonWorld.make()
        let singer = try await build(w, w.kishore, .singer), actor = try await build(w, w.kishore, .actor)
        #expect(names(singer, .topSongs) == ["Ek Ladki Bheegi Bhaagi Si"] && singer.section(.filmography) == nil)
        #expect(names(actor, .filmography) == ["Chalti Ka Naam Gaadi"] && actor.section(.topSongs) == nil)
    }

    @Test func personWithNoCreditsBuildsAnEmptyViewWithoutHeadings() async throws {
        let w = try await PersonWorld.make()
        for v in MusicPersonView.allCases {
            let d = try await build(w, w.nobody, v)
            #expect(d.isEmpty && d.visible.isEmpty && d.complete)
        }
    }

    // MARK: bounds and outage

    @Test func readBudgetBoundsTheWorkAndReportsTruncation() async throws {
        let w = try await PersonWorld.make()
        let d = try await build(w, w.mukesh, .singer, maxReads: 6)
        #expect(d.truncated && d.complete)
        #expect(d.section(.topSongs) != nil)      // what was read is kept
        let reader = MusicPersonReader(store: w.store, person: w.mukesh, maxReads: 6)
        _ = try await reader.build(.singer)
        #expect(await reader.readsSpent <= 6)
    }

    @Test func aStoreThatFailsSomeReadsStillYieldsTheRest() async throws {
        let w = try await PersonWorld.make()
        let flaky = FlakyGraph(base: w.store, failIncoming: [.playlistContains], failEntities: [w.lata])
        let d = try await build(w, w.mukesh, .singer, store: flaky)
        #expect(names(d, .topSongs).first == "Awaara Hoon")
        #expect(d.section(.playlists) == nil)                      // that facet failed: hidden, not an error banner
        #expect(!names(d, .collaborations).contains("Lata Mangeshkar"))   // a person who cannot be read is left out, not shown nameless
        #expect(names(d, .composersWorkedWith).first == "Shankar-Jaikishan")
    }

    @Test func listsAreDeterministic() async throws {
        let w = try await PersonWorld.make()
        let a = try await build(w, w.mukesh, .singer), b = try await build(w, w.mukesh, .singer)
        #expect(a == b)
    }
}

final class PersonBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
}
extension PersonBox where T == [Int] { func append(_ x: Int) { lock.withLock { v.append(x) } } }
extension PersonBox where T == [Bool] { func append(_ x: Bool) { lock.withLock { v.append(x) } } }
