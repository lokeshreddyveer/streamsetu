import Testing
import Foundation
@testable import REDDY

@Suite struct DownloadTests {
    @Test func theFileNameIsSafeAndKeepsTheKindOfFile() {
        let name = DownloadNaming.fileName(itemID: "3F2A|movie|123", url: URL(string: "http://host/movie/u/p/123.mkv")!)
        #expect(name == "3F2A_movie_123.mkv")
        #expect(!name.contains("|") && !name.contains("/"))
        #expect(DownloadNaming.fileName(itemID: "x", url: URL(string: "http://host/movie/u/p/123")!) == "x.mp4")                 // no usable type: mp4
        #expect(DownloadNaming.fileName(itemID: "x", url: URL(string: "http://host/a.php?x=1")!) == "x.mp4")
    }

    @Test func aListOfPiecesCannotBeSavedAsOneFile() {
        #expect(DownloadNaming.isStreamingList(URL(string: "http://host/a/b.m3u8")!))
        #expect(!DownloadNaming.isStreamingList(URL(string: "http://host/a/b.mp4")!))
        #expect(!DownloadNaming.isStreamingList(URL(string: "http://host/movie/u/p/1.mkv")!))
    }

    @Test func aSavedFileIsFoundOnlyWhenTheDownloadIsDoneAndTheFileIsThere() throws {
        let db = try TestSupport.makeDB()
        let id = "test-\(UUID().uuidString)"
        let file = DownloadService.folder.appendingPathComponent("\(id).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        func put(_ state: String) throws {
            try db.write { c in
                try c.execute("INSERT OR REPLACE INTO downloads(item_id, kind, source_id, title, file_name, state, added_at) VALUES(?,?,?,?,?,?,?)",
                              [id, "movie", UUID(), "T", "\(id).mp4", state, Date()])
            }
        }
        try put("done")
        #expect(DownloadService.savedFile(for: id, in: db) == nil)                         // done, but the file is gone
        try Data("x".utf8).write(to: file)
        #expect(DownloadService.savedFile(for: id, in: db) == file)
        try put("downloading")
        #expect(DownloadService.savedFile(for: id, in: db) == nil)                         // not finished
        #expect(DownloadService.savedFile(for: "other", in: db) == nil)
    }

    @Test func theLocalFinderIsAskedOnlyWhenItWasSet() {
        let files = LocalFiles()
        #expect(files.url(for: "a") == nil)
        files.set { $0 == "a" ? URL(fileURLWithPath: "/tmp/a.mp4") : nil }
        #expect(files.url(for: "a")?.lastPathComponent == "a.mp4")
        #expect(files.url(for: "b") == nil)
    }

    @Test func aRecordShowsHowFarItIs() {
        var r = DownloadRecord(itemID: "a", kind: .movie, sourceID: UUID(), seriesID: nil, title: "T", subtitle: nil, artworkURL: nil, fileName: nil, state: .downloading, bytesDone: 250, bytesTotal: 1000, addedAt: Date(), error: nil)
        #expect(r.fraction == 0.25)
        r.bytesTotal = 0
        #expect(r.fraction == 0)                                  // the size is not known yet
        r.bytesDone = 5000; r.bytesTotal = 1000
        #expect(r.fraction == 1)                                  // never more than whole
    }
}
