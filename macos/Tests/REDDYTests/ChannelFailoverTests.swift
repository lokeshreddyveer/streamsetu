import Testing
import Foundation
@testable import REDDY

@Suite struct ChannelFailoverTests {
    @Test func theSameChannelInAnotherPlaylistIsFoundButNotInADisabledOneOrTheSame() throws {
        let db = try TestSupport.makeDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B"), off = try TestSupport.makeSource(db, name: "Off")
        let mine = TestSupport.channel(a, "1", "Star Sports 1")
        let theirs = TestSupport.channel(b, "9", "Star Sports 1")
        let other = TestSupport.channel(b, "8", "Zee News")
        let disabled = TestSupport.channel(off, "5", "Star Sports 1")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitChannels(source: a, categories: [], channels: [mine])
        try indexer.commitChannels(source: b, categories: [], channels: [theirs, other])
        try indexer.commitChannels(source: off, categories: [], channels: [disabled])
        try db.write { try $0.execute("UPDATE sources SET enabled = 0 WHERE id = ?", [off.id.uuidString.lowercased()]) }
        let found = try catalog.channelCopiesInOtherPlaylists(of: mine)
        #expect(found.map(\.id) == [theirs.id])
    }

    @Test func aGuideIdAlsoMatchesWhenTheNamesDiffer() throws {
        let db = try TestSupport.makeDB()
        let catalog = SQLiteCatalogRepository(db: db)
        let a = try TestSupport.makeSource(db, name: "A"), b = try TestSupport.makeSource(db, name: "B")
        let mine = TestSupport.channel(a, "1", "BBC One HD", epg: "bbc1.uk")
        let theirs = TestSupport.channel(b, "2", "BBC 1 London", epg: "bbc1.uk")
        let indexer = CatalogIndexer(db: db)
        try indexer.commitChannels(source: a, categories: [], channels: [mine])
        try indexer.commitChannels(source: b, categories: [], channels: [theirs])
        #expect(try catalog.channelCopiesInOtherPlaylists(of: mine).map(\.id) == [theirs.id])
    }
}
