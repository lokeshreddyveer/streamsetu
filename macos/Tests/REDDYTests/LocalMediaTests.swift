import Testing
import Foundation
@testable import REDDY

@Suite struct LocalMediaTests {
    @Test func videoAndSubtitleExtensionsAreRecognised() {
        for n in ["a.mkv", "a.AVI", "a.mp4", "a.MOV", "a.ts"] { #expect(LocalMedia.isVideo(n)) }
        for n in ["a.srt", "a.VTT", "a.ass"] { #expect(LocalMedia.isSubtitle(n)) }
        #expect(!LocalMedia.isVideo("a.txt") && !LocalMedia.isVideo("a.srt") && !LocalMedia.isSubtitle("a.mkv"))
    }

    @Test func titlesLoseDotsUnderscoresAndExtension() {
        #expect(LocalMedia.title(fromFileName: "My.Movie.2020.1080p.mkv") == "My Movie 2020 1080p")
        #expect(LocalMedia.title(fromFileName: "Holiday_Clip.mp4") == "Holiday Clip")
    }

    @Test func subtitlesBesideAVideoAreMatchedByName() {
        let names = ["Movie.mkv", "Movie.srt", "Movie.en.srt", "Movie.English.vtt", "Other.srt", "Movie2.srt", "Movie.txt"]
        #expect(LocalMedia.sidecars(of: "Movie.mkv", among: names) == ["Movie.English.vtt", "Movie.en.srt", "Movie.srt"])
        #expect(LocalMedia.sidecars(of: "Nothing.mkv", among: names).isEmpty)
    }

    @Test func sidecarsAreFoundOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["Film.mkv", "Film.srt", "Else.srt"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        let found = LocalMedia.sidecarURLs(for: dir.appendingPathComponent("Film.mkv"))
        #expect(found.map(\.lastPathComponent) == ["Film.srt"])
    }

    @Test func theSameFileAlwaysGetsTheSameId() {
        #expect(LocalMedia.itemID("x") == LocalMedia.itemID("x"))
        #expect(LocalMedia.itemID("x") != LocalMedia.itemID("y"))
        #expect(LocalMedia.itemID("x").hasPrefix("local:"))
    }

    @Test func aFolderListingShowsFoldersFirstAndOnlyMedia() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Season 1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["b.mkv", "a.mp4", "notes.txt", "a.srt"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8)) }
        let list = try MediaListing.local(dir)
        #expect(list.map(\.name) == ["Season 1", "a.mp4", "a.srt", "b.mkv"])
        #expect(list.first?.isFolder == true)
    }

    @Test func aWebDAVAnswerIsReadIntoEntries() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/video/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/video/Season%201/</d:href><d:propstat><d:prop><d:displayname>Season 1</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/video/Film%20One.mkv</d:href><d:propstat><d:prop><d:displayname>Film One.mkv</d:displayname><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength></d:prop></d:propstat></d:response>
          <d:response><d:href>/video/readme.txt</d:href><d:propstat><d:prop><d:displayname>readme.txt</d:displayname><d:resourcetype/></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let folder = URL(string: "https://nas.local:5006/video/")!
        let list = WebDAVClient.parse(Data(xml.utf8), folder: folder)
        #expect(list.map(\.name) == ["Season 1", "Film One.mkv"])
        #expect(list[0].isFolder && !list[1].isFolder && list[1].size == 1234)
        #expect(list[1].location.absoluteString == "https://nas.local:5006/video/Film%20One.mkv")
    }

    @Test func theLoginTravelsAsAHeader() {
        let c = WebDAVClient(base: URL(string: "https://x")!, username: "me", password: "pw")
        #expect(c.headers["Authorization"] == "Basic " + Data("me:pw".utf8).base64EncodedString())
        #expect(WebDAVClient(base: URL(string: "https://x")!, username: nil, password: nil).headers.isEmpty)
    }

    @Test func savedSourcesKeepTheirPasswordInTheCredentialStore() {
        let defaults = UserDefaults(suiteName: "lm-\(UUID().uuidString)")!
        let creds = InMemoryCredentialStore()
        let store = FileSourceStore(defaults: defaults, credentials: creds)
        let s = FileSource(kind: .webdav, name: "NAS", address: "https://nas", username: "me")
        store.add(s, password: "secret")
        #expect(store.all().count == 1 && store.password(for: s) == "secret")
        let stored = String(data: defaults.data(forKey: "files.sources.v1")!, encoding: .utf8)!
        #expect(!stored.contains("secret"))
        store.remove(s)
        #expect(store.all().isEmpty && store.password(for: s) == nil)
    }
}
