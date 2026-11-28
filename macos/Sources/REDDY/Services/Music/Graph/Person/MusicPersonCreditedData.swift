import Foundation

// Pages for the credits that are not a singer, composer, lyricist, actor or director: a producer, an instrumentalist, a conductor and a record label. Each reads
// only what the graph holds (the person's credited recordings, the releases they sit on, the films they belong to, and who else is credited beside them); a
// page with nothing behind it shows no heading. Also the solo work of a band's members.

extension MusicPersonReader {
    /// A credit view with one list of songs, then albums, films and the people credited alongside.
    func buildCredited(_ view: MusicPersonView, songs songsID: MusicPersonSectionID, report: @escaping Report) async throws -> MusicPersonViewData {
        var sections: [MusicPersonSection] = []
        let songs = await works(view: view, kinds: Self.songKinds, cap: Self.compositions)
        var listed = songs.map { entry($0.snap, edge: $0.edge) }
        sections.append(Self.cut(songsID, listed, to: Self.compositions))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let rel = await releases(view: view, songs: songs, cap: Self.albumCap)
        sections.append(Self.cut(.albums, (rel.albums + rel.singles).sorted(by: Self.newestFirst), to: Self.grid))
        sections.append(Self.cut(.films, await filmsOfSongs(songs), to: Self.grid))
        await report(data(view, sections, complete: false))
        try Task.checkCancellation()

        let workIDs = Array(songs.prefix(40).map(\.snap.id))
        let sing = await observations(of: workIDs, roles: MusicPersonView.singer.roles, releaseLevel: true, filmLevel: false)
        let comp = await observations(of: workIDs, roles: MusicPersonView.composer.roles)
        sections.append(Self.cut(.singers, await collaboratorEntries(MusicCollaboration.rank(sing, excluding: [person], limit: 24)) { .sharedWorks($0.workCount) }, to: Self.grid))
        sections.append(Self.cut(.composers, await collaboratorEntries(MusicCollaboration.rank(comp, excluding: [person], limit: 24)) { .sharedWorks($0.workCount) }, to: Self.grid))
        sections.append(Self.cut(.frequentCollaborators, await collaboratorEntries(MusicCollaboration.rank(comp + sing, excluding: [person], limit: 24)) { .sharedWorks($0.workCount) }, to: Self.grid))
        let near = MusicCollaboration.rank(comp + sing, excluding: [person], limit: 3)
        sections.append(Self.cut(.relatedArtists, await relatedPeers(through: near, roles: view.roles), to: Self.shelf))
        for i in listed.indices.prefix(12) { listed[i].detail = await performerLine(of: listed[i].id, excluding: [person]) }
        sections[0] = Self.cut(songsID, listed, to: Self.compositions)
        return data(view, sections, complete: true)
    }

    /// The albums each member of a group made on their own: releases the member is credited on that the group itself is not. At most three albums for each
    /// of eight members, each carrying the member's name.
    func soloCareers() async -> [MusicPersonEntry] {
        let members = await membersOfGroup()
        var out: [MusicPersonEntry] = []
        for m in members.prefix(8) {
            if Task.isCancelled { break }
            let reader = MusicPersonReader(store: store, person: m.id)
            let songs = await reader.works(view: .singer, kinds: Self.songKinds, cap: 30)
            let rel = await reader.releases(view: .singer, songs: songs, cap: 8)
            var taken = 0
            for a in (rel.albums + rel.singles) where taken < 3 {
                let credited = await outgoing(a.id).contains { $0.predicate == .performedBy && $0.object == person }
                if credited { continue }
                var e = a
                e.detail = m.name
                out.append(e)
                taken += 1
            }
        }
        return MusicPersonReader.unique(out)
    }
}
