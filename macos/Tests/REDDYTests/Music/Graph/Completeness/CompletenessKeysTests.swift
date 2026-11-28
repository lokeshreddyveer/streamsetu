import Foundation
import Testing
@testable import REDDY

@Suite("Completeness: keys and the ledger") struct CompletenessKeysTests {
    @Test func editionWordsAndLanguageTagsAreNotPartOfTheIdentity() {
        let a = MusicPersonWorkKey.parse("Vaathi (Original Motion Picture Soundtrack)")
        let b = MusicPersonWorkKey.parse("Vaathi")
        let c = MusicPersonWorkKey.parse("Vaathi - Original Motion Picture Soundtrack")
        let d = MusicPersonWorkKey.parse("Vaathi (Tamil) [Deluxe Edition]")
        #expect(a.key == b.key && b.key == c.key && c.key == d.key && !a.key.isEmpty)
        #expect(a.soundtrackWording && c.soundtrackWording && !b.soundtrackWording)
        #expect(d.lang == "ta")
        #expect(MusicPersonWorkKey.parse("Soorarai Pottru (From \"Soorarai Pottru\")").filmHint == "Soorarai Pottru")
    }

    @Test func realQualifiersStayInTheKey() {
        #expect(MusicPersonWorkKey.parse("Aadukalam (Remix)").key != MusicPersonWorkKey.parse("Aadukalam").key)
        #expect(MusicPersonWorkKey.parse("Asuran").key != MusicPersonWorkKey.parse("Asuran 2").key)
    }

    @Test func ledgerJoinsOneAlbumFromThreeSourcesAndKeepsDubsApart() {
        var l = MusicPersonWorkLedger()
        let wd = MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2023, subkind: "soundtrack", ids: [ExternalID(.wikidata, "Q211")], source: .wikidata)
        let mb = MusicPersonWork(kind: .album, title: "Vaathi", year: 2023, subkind: "soundtrack", ids: [ExternalID(.mbReleaseGroup, "rg1")], source: .musicbrainz)
        var jio = providerAlbum("a1", "Vaathi (Tamil)", year: 2023); jio.lang = "ta"
        var tel = providerAlbum("a2", "Vaathi (Telugu)", year: 2023); tel.lang = "te"
        for w in [wd, mb, jio, tel] { l.add(w) }
        #expect(l.count(.album) == 2)
        #expect(l.albums.first { $0.members.count == 3 }?.sources == [.wikidata, .musicbrainz, "jiosaavn"])
    }

    @Test func sameTitleFarApartInYearsAreDifferentAlbums() {
        var l = MusicPersonWorkLedger()
        l.add(MusicPersonWork(kind: .album, title: "Greatest Hits", year: 2010, source: .musicbrainz))
        l.add(MusicPersonWork(kind: .album, title: "Greatest Hits", year: 2020, source: .musicbrainz))
        #expect(l.count(.album) == 2)
    }

    @Test func aSharedStrongIDJoinsTwoSpellings() {
        var l = MusicPersonWorkLedger()
        l.add(MusicPersonWork(kind: .film, title: "Jigarthanda", year: 2014, ids: [ExternalID(.imdbTitle, "tt2")], source: .imdb))
        l.add(MusicPersonWork(kind: .film, title: "ஜிகர்தண்டா", year: 2014, ids: [ExternalID(.imdbTitle, "tt2"), ExternalID(.wikidata, "Q9")], source: .wikidata))
        #expect(l.count(.film) == 1)
    }

    @Test func soundtrackPairsAreStatedOrInferredNeverFromAnArbitraryTitle() {
        let film = MusicPersonWork(kind: .film, title: "Vaathi", year: 2023, ids: [ExternalID(.wikidata, "Q111")], source: .wikidata)
        var stated = film; stated.soundtrackQID = "Q211"
        let st = MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2023, subkind: "soundtrack", ids: [ExternalID(.wikidata, "Q211")], source: .wikidata)
        let plain = MusicPersonWork(kind: .album, title: "Vaathi", year: 2023, subkind: "album", ids: [ExternalID(.mbReleaseGroup, "x")], source: .musicbrainz)
        let farYear = MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2015, subkind: "soundtrack", source: .musicbrainz)
        let p = MusicPersonWorkWriter.soundtrackPairs(albums: [st, plain, farYear], films: [stated])
        #expect(p.count == 1 && p[0].stated && p[0].album == 0)
        let q = MusicPersonWorkWriter.soundtrackPairs(albums: [MusicPersonWork(kind: .album, title: "Vaathi (Original Motion Picture Soundtrack)", year: 2023, subkind: "soundtrack", source: .musicbrainz), plain, farYear], films: [film])
        #expect(q.count == 1 && !q[0].stated && q[0].album == 0 && q[0].confidence == 0.8)
    }
}
