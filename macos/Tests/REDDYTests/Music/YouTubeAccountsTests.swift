import Foundation
import Testing
@testable import REDDY

// Offline tests for the YouTube Music account layer. Fixtures are canned JSON built from the field paths the parsers read; none of it
// has been compared with live replies. Secrets go to an in-memory store, never the Keychain.

private final class AcctTransport: MusicHTTPTransport, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> Reply
    init(_ h: @escaping @Sendable (URLRequest) -> Reply) { handler = h }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let r = handler(request)
        guard let url = request.url, let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: nil, headerFields: r.headers) else { throw MusicError.network("stub") }
        return (r.body, resp)
    }
    var requests: [URLRequest] { lock.withLock { log } }
    func last(_ suffix: String) -> URLRequest? { requests.last { ($0.url?.path ?? "").hasSuffix(suffix) } }
    func count(_ suffix: String) -> Int { requests.filter { ($0.url?.path ?? "").hasSuffix(suffix) }.count }
}

private func reply(_ json: String, status: Int = 200) -> AcctTransport.Reply { AcctTransport.Reply(status: status, body: Data(json.utf8)) }
private func parse(_ json: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:] }
private func body(_ r: URLRequest?) -> [String: Any] {
    guard let d = r?.httpBody, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}
private func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }
private func onBehalf(_ r: URLRequest?) -> String? { ((body(r)["context"] as? [String: Any])?["user"] as? [String: Any])?["onBehalfOfUser"] as? String }

private let cookieA = "SID=sid-a; SAPISID=sapi-a; __Secure-1PSIDTS=ts1"
private let cookieB = "SID=sid-b; SAPISID=sapi-b; __Secure-1PSIDTS=tsB"

// MARK: fixtures

private func menuJSON(name: String, sync: String? = "111||333", visitor: String = "CgtLOGIN") -> String {
    let sy = sync.map { #","mainAppWebResponseContext":{"datasyncId":"\#($0)"}"# } ?? ""
    let header = name.isEmpty ? "{}" : #"""
    {"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"\#(name)"}]},"channelHandle":{"runs":[{"text":"@\#(name.lowercased())"}]},
    "email":{"runs":[{"text":"\#(name.lowercased())@example.com"}]},"accountPhoto":{"thumbnails":[{"url":"https://p/small"},{"url":"https://p/big"}]},
    "navigationEndpoint":{"browseEndpoint":{"browseId":"UCchan\#(name)"}}}}
    """#
    return #"""
    {"responseContext":{"visitorData":"\#(visitor)"\#(sy)},"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"sections":[\#(header)]}}}}]}
    """#
}

private func item(name: String, tokens: String, selected: Bool = false, disabled: Bool? = nil, hasChannel: Bool? = nil, endpoint: Bool = true) -> String {
    var extra = ""
    if let disabled { extra += #","isDisabled":\#(disabled)"# }
    if let hasChannel { extra += #","hasChannel":\#(hasChannel)"# }
    let svc = endpoint ? #","serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[\#(tokens)]}}"# : ""
    return #"""
    {"accountItem":{"accountName":{"simpleText":"\#(name)"},"channelHandle":{"runs":[{"text":"@\#(name.lowercased())"}]},
    "accountPhoto":{"thumbnails":[{"url":"https://p/\#(name)"}]},"isSelected":\#(selected),"navigationEndpoint":{"browseEndpoint":{"browseId":"UC\#(name)"}}\#(extra)\#(svc)}}
    """#
}

private func sync(_ v: String) -> String { #"{"datasyncIdToken":{"datasyncIdToken":"\#(v)"}}"# }
private func pageTok(_ v: String) -> String { #"{"pageIdToken":{"pageId":"\#(v)"}}"# }

private func listJSON(_ items: [String], responseSync: String? = nil) -> String {
    let rc = responseSync.map { #""responseContext":{"mainAppWebResponseContext":{"datasyncId":"\#($0)"}},"# } ?? ""
    return #"""
    {\#(rc)"actions":[{"getMultiPageMenuAction":{"menu":{"multiPageMenuRenderer":{"sections":[{"accountSectionListRenderer":{
    "header":{"googleAccountHeaderRenderer":{"email":{"runs":[{"text":"group@example.com"}]}}},
    "contents":[{"accountItemSectionRenderer":{"contents":[\#(items.joined(separator: ","))]}}]}}]}}}}]}
    """#
}

// MARK: cookies and keys

@Suite struct YouTubeAccountKeyTests {
    @Test func keyIsStableAcrossRotationAndDiffersPerAccount() {
        let a1 = YTMCookieJar(header: "SAPISID=sapi-a; __Secure-1PSIDTS=old").accountKey
        let a2 = YTMCookieJar(header: "SAPISID=sapi-a; __Secure-1PSIDTS=new; EXTRA=1").accountKey
        let b = YTMCookieJar(header: "SAPISID=sapi-b").accountKey
        #expect(a1 != nil && a1 == a2)
        #expect(a1 != b)
        #expect(a1?.hasPrefix("ga-") == true)
        #expect(a1?.contains("sapi-a") == false)
    }

    @Test func fallsBackToTheSecureLoginCookieAndNeedsOne() {
        #expect(YTMCookieJar(header: "__Secure-3PAPISID=zzz").isSignedIn)
        #expect(YTMCookieJar(header: "SID=only").accountKey == nil)
        #expect(YouTubeMusicAccountStore.accountID(forCookieHeader: "SID=1") == nil)
    }

    @Test func mergeReplacesInPlaceAppendsAndIgnoresEmptyValues() {
        var jar = YTMCookieJar(header: "A=1; SAPISID=s; B=2")
        let changed = jar.merge([("A", "9"), ("C", "3"), ("SAPISID", ""), ("", "x")])
        #expect(changed)
        #expect(jar.header == "A=9; SAPISID=s; B=2; C=3")
        #expect(jar.merge([("A", "9")]) == false)
    }

    @Test func exportKeepsYouTubeDomainsLongestWinsAndSorts() {
        let jar = YTMCookieJar.export(from: [
            YTMWebCookie(name: "SAPISID", value: "wide", domain: ".youtube.com"),
            YTMWebCookie(name: "SAPISID", value: "narrow", domain: "music.youtube.com"),
            YTMWebCookie(name: "SID", value: "g", domain: ".google.com"),
            YTMWebCookie(name: "A", value: "1", domain: "youtube.com"),
            YTMWebCookie(name: "NOTYT", value: "x", domain: "notyoutube.com")
        ])
        #expect(jar.header == "A=1; SAPISID=narrow")
        #expect(YTMCookieJar.isYouTubeDomain(".youtube.com"))
        #expect(YTMCookieJar.isYouTubeDomain("music.youtube.com"))
        #expect(!YTMCookieJar.isYouTubeDomain("evilyoutube.com"))
    }

    @Test func sameSetIgnoresOrder() {
        #expect(YTMCookieJar(header: "a=1; b=2").sameSet(as: YTMCookieJar(header: "b=2; a=1")))
        #expect(!YTMCookieJar(header: "a=1; b=2").sameSet(as: YTMCookieJar(header: "a=1; b=3")))
    }
}

// MARK: session

@Suite struct YouTubeSessionImplTests {
    @Test func noCookieMeansNoIdentity() async {
        let s = YouTubeMusicSessionImpl(visitorData: "CgtV")
        s.setIdentity(dataSyncID: "sync", pageID: "page")
        let snap = await s.snapshot()
        #expect(snap.cookieHeader == nil && snap.dataSyncID == nil && snap.pageID == nil)
        #expect(snap.visitorData == "CgtV")
        #expect(!snap.isSignedIn)
    }

    @Test func pageIDOnlyWhileItsIdentityIsCurrent() async {
        let s = YouTubeMusicSessionImpl()
        s.activate(cookieHeader: cookieA, visitorData: "v", dataSyncID: "sync1", pageID: "page1")
        #expect(await s.snapshot().pageID == "page1")
        s.setIdentity(dataSyncID: "sync2", pageID: nil)
        let snap = await s.snapshot()
        #expect(snap.dataSyncID == "sync2" && snap.pageID == nil)
    }

    @Test func heldSessionLooksLikeAGuest() async {
        let s = YouTubeMusicSessionImpl()
        s.activate(cookieHeader: cookieA, visitorData: "v", dataSyncID: nil, pageID: nil, held: true)
        let snap = await s.snapshot()
        #expect(snap.cookieHeader == nil && snap.visitorData == "v")
        #expect(!s.isSignedIn)
        s.setHeld(false)
        #expect(await s.snapshot().isSignedIn)
    }

    @Test func rotatedCookiesMergeAndReportTheAccountKeyFromTheJar() async {
        let s = YouTubeMusicSessionImpl()
        let seen = Box<[String]>([])
        s.setRotationObserver { key, header in seen.value += [key + "|" + header] }
        s.activate(cookieHeader: cookieA, visitorData: nil, dataSyncID: nil, pageID: nil)
        await s.merge(rotatedCookies: [("__Secure-1PSIDTS", "ts2"), ("SAPISID", "")])
        let header = await s.snapshot().cookieHeader
        #expect(header?.contains("__Secure-1PSIDTS=ts2") == true)
        #expect(header?.contains("SAPISID=sapi-a") == true)
        #expect(seen.value.count == 1 && seen.value[0].hasPrefix(YTMCookieJar(header: cookieA).accountKey ?? "?"))
        await s.merge(rotatedCookies: [("__Secure-1PSIDTS", "ts2")])
        #expect(seen.value.count == 1)
    }

    @Test func guestIgnoresRotation() async {
        let s = YouTubeMusicSessionImpl()
        await s.merge(rotatedCookies: [("SAPISID", "x")])
        #expect(await s.snapshot().cookieHeader == nil)
    }

    @Test func uploadStreamsGetTheCookieOnlyWhenSignedIn() {
        let signed = YouTubeMusicSessionSnapshot(cookieHeader: cookieA)
        #expect(YTMUploadStreamHeaders.apply(to: ["User-Agent": "u"], snapshot: signed, isUpload: true)["Cookie"] == cookieA)
        #expect(YTMUploadStreamHeaders.apply(to: ["User-Agent": "u"], snapshot: signed, isUpload: false)["Cookie"] == nil)
        #expect(YTMUploadStreamHeaders.apply(to: [:], snapshot: YouTubeMusicSessionSnapshot(), isUpload: true)["Cookie"] == nil)
    }

    @Test func snapshotContextNeverCarriesAnIdentityWithoutACookie() {
        let guest = YouTubeMusicSessionSnapshot(visitorData: "v", dataSyncID: "sync")
        let ctx = YTMContext.build(client: YTMClientTable.builtIn[.webRemix]!, locale: YTMLocale(), session: guest)
        #expect(((ctx["user"] as? [String: Any])?["onBehalfOfUser"]) == nil)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

// MARK: store

@Suite struct YouTubeAccountStoreTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ytm-accounts-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func identity(_ n: String) -> YTMIdentity {
        YTMIdentity(dataSyncID: "sync-" + n, name: n, handle: "@" + n, email: nil, thumbnail: nil, channelID: nil, pageID: nil, hasMultiple: false)
    }

    @Test func listsOldestFirstAndReLoginKeepsTheOrder() {
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let store = YouTubeMusicAccountStore(directory: tempDir(), secrets: YTMMemorySecretStore(), now: { clock.value })
        let a = store.upsert(cookieHeader: cookieA, visitorData: "va", identity: identity("A"))
        clock.value = Date(timeIntervalSince1970: 2000)
        let b = store.upsert(cookieHeader: cookieB, visitorData: nil, identity: identity("B"))
        clock.value = Date(timeIntervalSince1970: 3000)
        store.upsert(cookieHeader: cookieA + "; NEW=1", visitorData: nil, identity: identity("A2"))
        let ids = store.list().map(\.id)
        #expect(ids == [a?.id ?? "", b?.id ?? ""])
        #expect(store.list().first?.identity?.name == "A2")
        #expect(store.cookie(for: a?.id ?? "")?.contains("NEW=1") == true)
    }

    @Test func secretsStayOutOfTheFileAndRemovalClearsThem() throws {
        let dir = tempDir(), secrets = YTMMemorySecretStore()
        let store = YouTubeMusicAccountStore(directory: dir, secrets: secrets)
        let rec = try #require(store.upsert(cookieHeader: cookieA, visitorData: "CgtSECRET", identity: identity("A")))
        store.setActive(rec.id)
        let text = try String(contentsOf: dir.appendingPathComponent(YouTubeMusicAccountStore.fileName), encoding: .utf8)
        #expect(!text.contains("sapi-a") && !text.contains("CgtSECRET") && !text.contains("sid-a"))
        #expect(store.activeID == rec.id)
        store.remove(rec.id)
        #expect(secrets.keys.isEmpty && store.list().isEmpty && store.activeID == nil)
    }

    @Test func reloadsFromDiskAndDropsRowsWithoutACredential() throws {
        let dir = tempDir(), secrets = YTMMemorySecretStore()
        let s1 = YouTubeMusicAccountStore(directory: dir, secrets: secrets)
        let a = try #require(s1.upsert(cookieHeader: cookieA, visitorData: nil, identity: identity("A")))
        let b = try #require(s1.upsert(cookieHeader: cookieB, visitorData: nil, identity: nil))
        s1.setActive(b.id)
        let s2 = YouTubeMusicAccountStore(directory: dir, secrets: secrets)
        #expect(s2.list().count == 2 && s2.active?.selectionPending == true)
        secrets.remove(YouTubeMusicAccountStore.cookieKey(a.id))
        let s3 = YouTubeMusicAccountStore(directory: dir, secrets: secrets)
        #expect(s3.list().map(\.id) == [b.id])
    }

    @Test func oldAndForeignFilesStillLoad() throws {
        let dir = tempDir(), secrets = YTMMemorySecretStore()
        let id = try #require(YouTubeMusicAccountStore.accountID(forCookieHeader: cookieA))
        secrets.set(cookieA, for: YouTubeMusicAccountStore.cookieKey(id))
        // A file with no version, an unknown field and a row without an identity.
        let json = #"{"activeID":"\#(id)","somethingNew":true,"accounts":[{"id":"\#(id)","addedAt":5}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(YouTubeMusicAccountStore.fileName))
        let store = YouTubeMusicAccountStore(directory: dir, secrets: secrets)
        #expect(store.active?.id == id && store.active?.selectionPending == true)
    }

    @Test func aCorruptFileIsSetAsideNotDeleted() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent(YouTubeMusicAccountStore.fileName)
        try Data("not json".utf8).write(to: url)
        let store = YouTubeMusicAccountStore(directory: dir, secrets: YTMMemorySecretStore())
        #expect(store.list().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }

    @Test func aLateRotationForARemovedRowDoesNotBringItBack() {
        let secrets = YTMMemorySecretStore()
        let store = YouTubeMusicAccountStore(directory: tempDir(), secrets: secrets)
        let id = YouTubeMusicAccountStore.accountID(forCookieHeader: cookieA) ?? ""
        store.updateCookie(id: id, header: cookieA)
        #expect(secrets.keys.isEmpty)
    }
}

// MARK: identity parsing

@Suite struct YouTubeIdentityParsingTests {
    @Test func normalisesDatasyncIDs() {
        #expect(YTMIdentityParser.normalizeDataSync("aaa||bbb") == "aaa")
        #expect(YTMIdentityParser.normalizeDataSync("||fallback") == "fallback")
        #expect(YTMIdentityParser.normalizeDataSync("||") == nil)
        #expect(YTMIdentityParser.normalizeDataSync("plain") == "plain")
        #expect(YTMIdentityParser.normalizeDataSync("  ") == nil)
    }

    @Test func readsTheAccountMenu() throws {
        let h = try #require(YTMIdentityParser.parseAccountMenu(parse(menuJSON(name: "Ada"))))
        #expect(h.name == "Ada" && h.handle == "@ada" && h.email == "ada@example.com")
        #expect(h.thumbnail == "https://p/big" && h.channelID == "UCchanAda")
        #expect(h.dataSyncID == "111" && h.visitorData == "CgtLOGIN")
    }

    @Test func anEmptyNameMeansTheCookieDidNotAuthenticate() {
        #expect(YTMIdentityParser.parseAccountMenu(parse(menuJSON(name: ""))) == nil)
    }

    @Test func oneIdentity() {
        let rows = YTMIdentityParser.parseAccountsList(parse(listJSON([item(name: "Ada", tokens: sync("111||222"), selected: true)])))
        #expect(rows.count == 1)
        #expect(rows[0].id == "111" && rows[0].pageID == nil && rows[0].isSelected && rows[0].email == "group@example.com")
    }

    @Test func aBrandChannelWithOnlyAPageIDUsesIt() {
        let rows = YTMIdentityParser.parseAccountsList(parse(listJSON([
            item(name: "Ada", tokens: sync("111||222"), selected: true),
            item(name: "Brand", tokens: pageTok("PAGE9"))
        ])))
        #expect(rows.map(\.id) == ["111", "PAGE9"])
        #expect(rows[1].pageID == "PAGE9")
    }

    @Test func emptyAndFallbackTokens() {
        let rows = YTMIdentityParser.parseAccountsList(parse(listJSON([
            item(name: "Empty", tokens: sync("||")),
            item(name: "Fall", tokens: sync("||fallback"))
        ])))
        #expect(rows.map(\.id) == ["fallback"])
    }

    @Test func skipsDisabledNoChannelNoEndpointAndNoTokenRows() {
        let rows = YTMIdentityParser.parseAccountsList(parse(listJSON([
            item(name: "Dis", tokens: sync("d1"), disabled: true),
            item(name: "NoChan", tokens: pageTok("PAGEX"), hasChannel: false),
            item(name: "NoEndpoint", tokens: "", endpoint: false),
            item(name: "NoTokens", tokens: ""),
            item(name: "Good", tokens: sync("g1"))
        ])))
        #expect(rows.map(\.id) == ["g1"])
    }

    @Test func neverInventsAnIDFromAChannelID() {
        // A selected row with no token uses the response's own id; an unselected one is omitted, and the UC id is never used.
        let withResp = YTMIdentityParser.parseAccountsList(parse(listJSON([item(name: "Sel", tokens: "", selected: true)], responseSync: "resp||x")))
        #expect(withResp.map(\.id) == ["resp"])
        let without = YTMIdentityParser.parseAccountsList(parse(listJSON([item(name: "Other", tokens: "")], responseSync: "resp")))
        #expect(without.isEmpty)
        #expect(!(withResp + without).contains { $0.id.hasPrefix("UC") })
    }

    @Test func dedupesByIDAndAcceptsTheAlternateTokenKeys() {
        let alt = #"{"dataSyncIdToken":{"dataSyncIdToken":"same||z"}}"#
        let rows = YTMIdentityParser.parseAccountsList(parse(listJSON([item(name: "One", tokens: alt), item(name: "Two", tokens: sync("same"))])))
        #expect(rows.count == 1 && rows[0].name == "One")
    }

    @Test func fallsBackToEveryAccountItemWhenThereIsNoSection() {
        let json = "{\"x\":[\(item(name: "Solo", tokens: sync("s1")))]}"
        #expect(YTMIdentityParser.parseAccountsList(parse(json)).map(\.id) == ["s1"])
    }

    @Test func theUIKeyHidesTheDelegatedID() {
        let r = YTMIdentityRow(id: "secret-id", pageID: nil, name: "n", isSelected: false)
        #expect(!r.selectionKey.contains("secret") && r.selectionKey == YTMIdentityRow.selectionKey(for: "secret-id"))
    }

    @Test func channelDecisions() {
        let h = YTMAccountHeader(name: "Ada", dataSyncID: "111", visitorData: nil)
        let one = YTMIdentityRow(id: "111", pageID: "P", name: "Ada", isSelected: true)
        let two = YTMIdentityRow(id: "222", pageID: "Q", name: "Brand", isSelected: false)
        // one identity: keep its page id only when ids match
        if case .use(let i) = YTMChannelDecision.decide(header: h, rows: [one], persistedID: nil) { #expect(i.dataSyncID == "111" && i.pageID == "P" && !i.hasMultiple) } else { Issue.record("expected use") }
        // many and nothing remembered: the person must pick
        #expect(YTMChannelDecision.decide(header: h, rows: [one, two], persistedID: nil) == .selectionRequired)
        // many with a remembered choice that is still listed: validate it
        #expect(YTMChannelDecision.decide(header: h, rows: [one, two], persistedID: "222") == .validate(id: "222", pageID: "Q", hasMultiple: true))
        // empty list with a remembered id: revalidate, never fall back to the default channel
        #expect(YTMChannelDecision.decide(header: h, rows: [], persistedID: "222") == .validate(id: "222", pageID: nil, hasMultiple: false))
        // a remembered id the list lacks belongs to another account: dropped
        #expect(YTMChannelDecision.decide(header: h, rows: [one, two], persistedID: "zzz") == .selectionRequired)
        // nothing exposed: header plus response id
        if case .use(let i) = YTMChannelDecision.decide(header: h, rows: [], persistedID: nil) { #expect(i.dataSyncID == "111") } else { Issue.record("expected use") }
    }
}

extension YTMAccountHeader {
    fileprivate init(name: String, dataSyncID: String?, visitorData: String?) {
        self.init(name: name, handle: nil, email: nil, thumbnail: nil, channelID: nil, dataSyncID: dataSyncID, visitorData: visitorData)
    }
}
extension YTMIdentityRow {
    fileprivate init(id: String, pageID: String?, name: String, isSelected: Bool) {
        self.init(id: id, pageID: pageID, name: name, handle: nil, email: nil, thumbnail: nil, channelID: nil, isSelected: isSelected)
    }
}

// MARK: write bodies

@Suite struct YouTubeWriteBodyTests {
    @Test func ratingPaths() {
        #expect(YTMWriteBodies.rate(.like, videoID: "v").path == "like/like")
        #expect(YTMWriteBodies.rate(.dislike, videoID: "v").path == "like/dislike")
        #expect(YTMWriteBodies.rate(.none, videoID: "v").path == "like/removelike")
        #expect(same(YTMWriteBodies.rate(.like, videoID: "v").body, ["target": ["videoId": "v"]]))
    }

    @Test func albumSaveIsALikeOnTheAudioPlaylist() {
        let w = YTMWriteBodies.savePlaylist(true, playlistID: "OLAK5uy_abc")
        #expect(w.path == "like/like" && same(w.body, ["target": ["playlistId": "OLAK5uy_abc"]]))
        let r = YTMWriteBodies.savePlaylist(false, playlistID: "VLPL123")
        #expect(r.path == "like/removelike" && same(r.body, ["target": ["playlistId": "PL123"]]))
    }

    @Test func createIsPrivateAndDeleteStripsVL() {
        #expect(same(YTMWriteBodies.create(title: "Mix"), ["title": "Mix", "privacyStatus": "PRIVATE"]))
        #expect(same(YTMWriteBodies.delete(playlistID: "VLPL1"), ["playlistId": "PL1"]))
    }

    @Test func editActionsUseTheExactFieldNames() {
        func j(_ a: YTMPlaylistEditAction) -> [String: Any] { a.json }
        #expect(same(j(.addVideo(videoID: "v", allowDuplicate: false)), ["action": "ACTION_ADD_VIDEO", "addedVideoId": "v"]))
        #expect(same(j(.addVideo(videoID: "v", allowDuplicate: true)), ["action": "ACTION_ADD_VIDEO", "addedVideoId": "v", "dedupeOption": "DEDUPE_OPTION_SKIP"]))
        #expect(same(j(.removeVideo(setVideoID: "s", videoID: "v")), ["action": "ACTION_REMOVE_VIDEO", "setVideoId": "s", "removedVideoId": "v"]))
        #expect(same(j(.moveBefore(setVideoID: "s", successor: "t")), ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": "s", "movedSetVideoIdSuccessor": "t"]))
        #expect(same(j(.moveBefore(setVideoID: "s", successor: nil)), ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": "s"]))
        #expect(same(j(.rename("N")), ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": "N"]))
        #expect(same(j(.describe("D")), ["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": "D"]))
        #expect(same(j(.privacy(.unlisted)), ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": "UNLISTED"]))
        #expect(same(j(.videoOrder(.topVoted)), ["action": "ACTION_SET_PLAYLIST_VIDEO_ORDER", "playlistVideoOrder": 6]))
        #expect(same(j(.dynamicSort(.album)), ["action": "ACTION_SET_PLAYLIST_DYNAMIC_SORT_PREFERENCE", "playlistDynamicSortPreference": 3]))
        let cover = j(.setCover(blobID: "BLOB"))
        #expect(cover["action"] as? String == "ACTION_SET_CUSTOM_THUMBNAIL")
        #expect(same(cover["addedCustomThumbnail"] ?? 0, ["imageKey": ["name": "studio_square_thumbnail", "type": "PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL"], "playlistScottyEncryptedBlobId": "BLOB"]))
        #expect(same(j(.removeCover)["deletedCustomThumbnail"] ?? 0, ["imageKey": ["name": "studio_square_thumbnail", "type": "PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL"]]))
    }

    @Test func sortEnumsHaveOnlyTheValuesYouTubeAccepts() {
        #expect(YTMPlaylistVideoOrder.allCases.map(\.rawValue) == [0, 1, 2, 6])
        #expect(YTMPlaylistDynamicSort.allCases.map(\.rawValue) == [1, 2, 3])
    }

    @Test func onlyChangedFieldsAreSent() {
        #expect(YTMPlaylistDetailsEdit().actions.isEmpty)
        #expect(YTMPlaylistDetailsEdit(name: "N", description: nil, privacy: .public).actions == [.rename("N"), .privacy(.public)])
    }

    @Test func subscribeBodies() {
        let s = YTMWriteBodies.subscribe(true, channelIDs: ["UC1"])
        #expect(s.path == "subscription/subscribe" && same(s.body, ["channelIds": ["UC1"]]))
        #expect(YTMWriteBodies.subscribe(false, channelIDs: ["UC1"]).path == "subscription/unsubscribe")
    }

    @Test func editBodyStripsVLAndKeepsOrder() {
        let b = YTMWriteBodies.edit(playlistID: "VLPL9", actions: [.rename("A"), .describe("B")])
        #expect(b["playlistId"] as? String == "PL9")
        #expect((b["actions"] as? [[String: Any]])?.compactMap { $0["action"] as? String } == ["ACTION_SET_PLAYLIST_NAME", "ACTION_SET_PLAYLIST_DESCRIPTION"])
    }

    @Test func protectedTargets() {
        #expect(!YTMIDs.isEditable("VLLM") && !YTMIDs.isEditable("LM") && !YTMIDs.isEditable("RDAMVMx") && !YTMIDs.isEditable("FEmusic_liked_videos"))
        #expect(YTMIDs.isEditable("VLPLabc"))
    }

    @Test func resultReading() {
        #expect(YTMWriteResults.feedbackProcessed(parse(#"{"feedbackResponses":[{"isProcessed":true}]}"#)))
        #expect(!YTMWriteResults.feedbackProcessed(parse(#"{"feedbackResponses":[{"isProcessed":false}]}"#)))
        #expect(!YTMWriteResults.feedbackProcessed(parse("{}")))
        #expect(YTMWriteResults.createdPlaylistID(parse(#"{"status":"STATUS_SUCCEEDED","playlistId":"PLnew"}"#)) == "PLnew")
        #expect(YTMWriteResults.edit(parse(#"{"status":"STATUS_SUCCEEDED"}"#)) == .applied)
        #expect(YTMWriteResults.edit(parse(#"{"status":"STATUS_FAILED"}"#)) == .refused)
        #expect(YTMWriteResults.edit(parse(#"{"status":"STATUS_FAILED","x":[{"dedupeOption":"DEDUPE_OPTION_SKIP"}]}"#)) == .duplicate)
        let added = YTMWriteResults.addedSetVideoIDs(parse(#"{"playlistEditResults":[{"playlistEditVideoAddedResultData":{"videoId":"v1","setVideoId":"s1"}}]}"#))
        #expect(added == ["v1": "s1"])
    }
}

// MARK: writer through the client

@Suite struct YouTubeWriterTests {
    private func makeClient(_ t: AcctTransport, signedIn: Bool = true) -> YouTubeMusicClient {
        let s = YouTubeMusicSessionImpl(visitorData: "CgtV")
        if signedIn { s.activate(cookieHeader: cookieA, visitorData: "CgtV", dataSyncID: "SYNC", pageID: nil) }
        return YouTubeMusicClient(http: MusicHTTP(transport: t), session: s, sleep: { _ in })
    }

    @Test func libraryWriteCarriesTheAccountAndFailsOnAStaleToken() async throws {
        let t = AcctTransport { _ in reply(#"{"feedbackResponses":[{"isProcessed":true}]}"#) }
        let w = YouTubeMusicWriter(client: makeClient(t))
        try await w.setLibrary(MusicLibraryToggle(inLibrary: false, addToken: "ADD", removeToken: "REM"), add: true)
        let req = try #require(t.last("/feedback"))
        #expect(body(req)["feedbackTokens"] as? [String] == ["ADD"])
        #expect(onBehalf(req) == "SYNC")
        #expect(req.value(forHTTPHeaderField: "cookie") == cookieA)
        #expect(req.value(forHTTPHeaderField: "authorization")?.hasPrefix("SAPISIDHASH ") == true)

        let stale = AcctTransport { _ in reply(#"{"feedbackResponses":[{"isProcessed":false}]}"#) }
        await #expect(throws: YTMAccountError.libraryChangeRefused) {
            try await YouTubeMusicWriter(client: makeClient(stale)).setLibrary(MusicLibraryToggle(inLibrary: true, addToken: nil, removeToken: "R"), add: false)
        }
    }

    @Test func signedOutWritesSendNothing() async {
        let t = AcctTransport { _ in reply("{}") }
        let w = YouTubeMusicWriter(client: makeClient(t, signedIn: false))
        await #expect(throws: YTMAccountError.signedOut) { try await w.rate(.like, videoID: "v") }
        #expect(t.requests.isEmpty)
    }

    @Test func createPlaylistReturnsTheIDAndIsPrivate() async throws {
        let t = AcctTransport { _ in reply(#"{"status":"STATUS_SUCCEEDED","playlistId":"PLnew"}"#) }
        let id = try await YouTubeMusicWriter(client: makeClient(t)).createPlaylist(title: "Mix")
        #expect(id == "PLnew")
        #expect(body(t.last("/playlist/create"))["privacyStatus"] as? String == "PRIVATE")
        let none = AcctTransport { _ in reply("{}") }
        await #expect(throws: YTMAccountError.noPlaylistID) { _ = try await YouTubeMusicWriter(client: makeClient(none)).createPlaylist(title: "x") }
    }

    @Test func addReportsDuplicatesAndHandles() async throws {
        let ok = AcctTransport { _ in reply(#"{"status":"STATUS_SUCCEEDED","playlistEditResults":[{"playlistEditVideoAddedResultData":{"videoId":"v","setVideoId":"S1"}}]}"#) }
        #expect(try await YouTubeMusicWriter(client: makeClient(ok)).add(videoID: "v", to: "VLPL1") == .added(setVideoID: "S1"))
        #expect(body(ok.last("/browse/edit_playlist"))["playlistId"] as? String == "PL1")
        let dup = AcctTransport { _ in reply(#"{"status":"STATUS_FAILED","actions":[{"dedupeOption":"DEDUPE_OPTION_SKIP"}]}"#) }
        #expect(try await YouTubeMusicWriter(client: makeClient(dup)).add(videoID: "v", to: "PL1") == .duplicate)
    }

    @Test func notYourPlaylistIsNotEditableAndNeverHeals() async {
        let t = AcctTransport { _ in reply("{}", status: 403) }
        await #expect(throws: YTMAccountError.notEditable) { _ = try await YouTubeMusicWriter(client: makeClient(t)).add(videoID: "v", to: "PL1") }
        #expect(t.count("/browse/edit_playlist") == 1)
    }

    @Test func refusedEditAndProtectedTargets() async {
        let t = AcctTransport { _ in reply(#"{"status":"STATUS_FAILED"}"#) }
        await #expect(throws: YTMAccountError.playlistEditRefused) { try await YouTubeMusicWriter(client: makeClient(t)).update("PL1", details: YTMPlaylistDetailsEdit(name: "x")) }
        await #expect(throws: YTMAccountError.notAllowedTarget) { try await YouTubeMusicWriter(client: makeClient(t)).remove([("s", "v")], from: "VLLM") }
    }

    @Test func nothingChangedSendsNothing() async throws {
        let t = AcctTransport { _ in reply("{}") }
        try await YouTubeMusicWriter(client: makeClient(t)).update("PL1", details: YTMPlaylistDetailsEdit())
        #expect(t.requests.isEmpty)
    }

    @Test func coverUploadRunsThreeStepsInOrder() async throws {
        let t = AcctTransport { r in
            let path = r.url?.path ?? ""
            if path.hasSuffix("playlist_custom_thumbnail") {
                if r.value(forHTTPHeaderField: "x-goog-upload-command") == "start" {
                    return AcctTransport.Reply(status: 200, headers: ["x-guploader-uploadid": "UP1"], body: Data())
                }
                return reply(#"{"encryptedBlobId":"BLOB1"}"#)
            }
            return reply(#"{"status":"STATUS_SUCCEEDED"}"#)
        }
        try await YouTubeMusicWriter(client: makeClient(t)).setCover(playlistID: "PL1", image: Data([1, 2, 3]))
        let reqs = t.requests.map { ($0.url?.path ?? "") + "?" + ($0.url?.query ?? "") }
        #expect(reqs.count == 3)
        #expect(reqs[1].contains("upload_id=UP1") && reqs[1].contains("upload_protocol=resumable"))
        let start = t.requests[0], send = t.requests[1]
        #expect(start.value(forHTTPHeaderField: "x-goog-upload-header-content-length") == "3" && start.value(forHTTPHeaderField: "x-goog-upload-protocol") == "resumable")
        #expect(send.value(forHTTPHeaderField: "x-goog-upload-command") == "upload, finalize" && send.httpBody == Data([1, 2, 3]))
        let actions = body(t.requests[2])["actions"] as? [[String: Any]]
        #expect(actions?.first?["action"] as? String == "ACTION_SET_CUSTOM_THUMBNAIL")
    }

    @Test func aRefusedCoverNamesThePhoneRequirement() async {
        let t = AcctTransport { r in
            if (r.url?.path ?? "").hasSuffix("playlist_custom_thumbnail") { return reply("{}", status: 400) }
            return reply("{}")
        }
        await #expect(throws: YTMAccountError.coverRefused) { try await YouTubeMusicWriter(client: makeClient(t)).setCover(playlistID: "PL1", image: Data([1])) }
    }
}

// MARK: library parsing

@Suite struct YouTubeLibraryParsingTests {
    private func rowWithMenu(_ vid: String, menu: String) -> String {
        #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\#(vid)"},"menu":{"menuRenderer":{"items":[\#(menu)]}}}}"#
    }
    private func toggle(_ d: String, _ t: String, _ dt: String, _ tt: String) -> String {
        #"{"toggleMenuServiceItemRenderer":{"defaultIcon":{"iconType":"\#(d)"},"toggledIcon":{"iconType":"\#(t)"},"defaultServiceEndpoint":{"feedbackEndpoint":{"feedbackToken":"\#(dt)"}},"toggledServiceEndpoint":{"feedbackEndpoint":{"feedbackToken":"\#(tt)"}}}}"#
    }

    @Test func addDirectionDefaultMeansNotInLibrary() {
        let t = YTMLibraryToggleParser.parse(menu: parse(#"{"items":[\#(toggle("LIBRARY_ADD", "LIBRARY_SAVED", "ADD_T", "REM_T"))]}"#))
        #expect(t == MusicLibraryToggle(inLibrary: false, addToken: "ADD_T", removeToken: "REM_T"))
    }

    @Test func removeDirectionDefaultMeansInLibrary() {
        let t = YTMLibraryToggleParser.parse(menu: parse(#"{"items":[\#(toggle("LIBRARY_SAVED", "LIBRARY_ADD", "REM_T", "ADD_T"))]}"#))
        #expect(t == MusicLibraryToggle(inLibrary: true, addToken: "ADD_T", removeToken: "REM_T"))
    }

    @Test func aPlainItemKnowsOneDirectionOnly() {
        let m = #"{"items":[{"menuServiceItemRenderer":{"icon":{"iconType":"BOOKMARK_BORDER"},"serviceEndpoint":{"feedbackEndpoint":{"feedbackToken":"ONLY"}}}}]}"#
        #expect(YTMLibraryToggleParser.parse(menu: parse(m)) == MusicLibraryToggle(inLibrary: false, addToken: "ONLY", removeToken: nil))
    }

    @Test func favouriteAndPinFeedbackAreNotTheLibrary() {
        let m = #"{"items":[{"menuServiceItemRenderer":{"icon":{"iconType":"FAVORITE"},"serviceEndpoint":{"feedbackEndpoint":{"feedbackToken":"FAV"}}}},{"menuServiceItemRenderer":{"icon":{"iconType":"KEEP"},"serviceEndpoint":{"feedbackEndpoint":{"feedbackToken":"PIN"}}}}]}"#
        #expect(YTMLibraryToggleParser.parse(menu: parse(m)) == nil)
    }

    @Test func togglesAreKeyedByVideo() {
        let root = parse("{\"contents\":[\(rowWithMenu("vid1", menu: toggle("LIBRARY_ADD", "LIBRARY_SAVED", "A", "R"))),\(rowWithMenu("vid2", menu: ""))]}")
        let t = YTMLibraryToggleParser.toggles(in: root)
        #expect(t.keys.sorted() == ["vid1"] && t["vid1"]?.addToken == "A")
    }

    @Test func ratingsMap() {
        #expect(YTMRowEnrichment.rating("LIKE") == .like && YTMRowEnrichment.rating("DISLIKE") == .dislike)
        #expect(YTMRowEnrichment.rating("INDIFFERENT") == MusicRating.none && YTMRowEnrichment.rating(nil) == nil)
    }

    @Test func rowEnrichmentCopiesTheHandleRatingAndToggle() {
        let track = MusicTrack(id: "v1", providerID: YTM.providerID, title: "T", durationMs: 1000, artists: [], videoID: "v1")
        let row = YTMRow(track: track, setVideoID: "SET1", rating: "LIKE")
        let t = YTMRowEnrichment.track(row, toggles: ["v1": MusicLibraryToggle(inLibrary: true, removeToken: "R")])
        #expect(t.setVideoID == "SET1" && t.rating == .like && t.libraryToggle?.removeToken == "R")
    }

    @Test func oldSavedTracksStillDecodeAndNewFieldsRoundTrip() throws {
        let old = #"{"id":"a","providerID":"p","title":"T","durationMs":5,"artists":[],"thumbnails":[],"explicit":false}"#
        let t = try JSONDecoder().decode(MusicTrack.self, from: Data(old.utf8))
        #expect(t.setVideoID == nil && t.rating == nil && t.libraryToggle == nil && t.counterpartVideoID == nil)
        var n = t
        n.setVideoID = "S"; n.rating = .dislike; n.counterpartVideoID = "c"; n.libraryToggle = MusicLibraryToggle(inLibrary: false, addToken: "x")
        let back = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(n))
        #expect(back == n)
    }
}

// MARK: history ping

@Suite struct YouTubeHistoryPingTests {
    @Test func thresholdIsHalfTheTrackAtMostThirtySeconds() {
        #expect(YTMHistoryPing.threshold(durationSeconds: 40) == 20)
        #expect(YTMHistoryPing.threshold(durationSeconds: 200) == 30)
        #expect(YTMHistoryPing.threshold(durationSeconds: 0) == 30)
        #expect(YTMHistoryPing.threshold(durationSeconds: 1) == 30)
    }

    @Test func latchesOncePerPlay() {
        #expect(!YTMHistoryPing.shouldPing(position: 19.9, durationSeconds: 40, sent: false))
        #expect(YTMHistoryPing.shouldPing(position: 20, durationSeconds: 40, sent: false))
        #expect(!YTMHistoryPing.shouldPing(position: 25, durationSeconds: 40, sent: true))
    }

    @Test func cpnIsSixteenURLSafeCharacters() {
        for _ in 0..<20 {
            let c = YTMHistoryPing.makeCPN()
            #expect(c.count == 16 && c.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
        #expect(YTMHistoryPing.makeCPN() != YTMHistoryPing.makeCPN())
    }

    @Test func urlChainsParametersAndKeepsAnExistingQuery() throws {
        let r = try #require(YTMHistoryPing.request(baseURL: "https://s.youtube.com/api/stats/playback?docid=abc&ei=1", clientName: "WEB_REMIX", cpn: "CPN1234567890123", playlistID: "PL1", pageID: nil))
        let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.map(\.name) == ["docid", "ei", "c", "cpn", "ver", "list", "referrer"])
        #expect(q.first { $0.name == "ver" }?.value == "2" && q.first { $0.name == "c" }?.value == "WEB_REMIX")
        #expect(r.url.host == "s.youtube.com" && r.extraHeaders.isEmpty)
    }

    @Test func aBrandChannelGoesToMusicWithThePageHeader() throws {
        let r = try #require(YTMHistoryPing.request(baseURL: "https://s.youtube.com/api/stats/playback?docid=abc", clientName: "WEB_REMIX", cpn: "c", pageID: "PAGE9"))
        #expect(r.url.host == "music.youtube.com" && r.extraHeaders["X-Goog-PageId"] == "PAGE9")
    }

    @Test func baseURLComesFromThePlayerAnswer() {
        let root = parse(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?x=1"}}}"#)
        #expect(YTMHistoryPing.baseURL(inPlayerResponse: root) == "https://s.youtube.com/api/stats/playback?x=1")
        #expect(YTMHistoryPing.baseURL(inPlayerResponse: parse("{}")) == nil)
    }

    @Test func reporterIsOffByDefaultAndSendsNothingUntilSwitchedOn() async throws {
        let t = AcctTransport { _ in reply("{}") }
        let s = YouTubeMusicSessionImpl(visitorData: "v")
        s.activate(cookieHeader: cookieA, visitorData: "v", dataSyncID: nil, pageID: nil)
        let client = YouTubeMusicClient(http: MusicHTTP(transport: t), session: s, sleep: { _ in })
        let suite = try #require(UserDefaults(suiteName: "ytm.history.test." + UUID().uuidString))
        let r = await MainActor.run { YTMHistoryReporter(client: client, defaults: suite) }
        await r.progress(videoID: "v", position: 100, durationSeconds: 200)
        #expect(t.requests.isEmpty)
    }
}

// MARK: healer

@Suite struct YouTubeHealerTests {
    @Test func aBurstIsOneHealAndTheCooldownHoldsForFiveMinutes() async {
        let clock = Box(Date(timeIntervalSince1970: 10_000))
        let count = Box(0)
        let h = YTMHealCoordinator(now: { clock.value }, sleep: { _ in await Task.yield() }, heal: { _ in
            count.value += 1
            try? await Task.sleep(nanoseconds: 30_000_000)
        })
        async let a = h.requestHeal(accountKey: "k")
        async let b = h.requestHeal(accountKey: "k")
        async let c = h.requestHeal(accountKey: "k")
        let all = await [a, b, c]
        #expect(all == [.finished, .finished, .finished])
        #expect(count.value == 1)
        clock.value = clock.value.addingTimeInterval(60)
        #expect(await h.requestHeal(accountKey: "k") == .cooledDown)
        #expect(count.value == 1)
        clock.value = clock.value.addingTimeInterval(241)
        #expect(await h.requestHeal(accountKey: "k") == .finished)
        #expect(count.value == 2)
        let done = await h.healsCompleted, running = await h.healsRunning
        #expect(done == 2 && running == 0)
    }

    @Test func aWaiterGivesUpAfterNinetySecondsWithNoHeal() async {
        let waited = Box<TimeInterval>(0)
        let h = YTMHealCoordinator(sleep: { waited.value += $0; await Task.yield() }, heal: { _ in })
        #expect(await h.waitForHeal() == .timedOut)
        #expect(waited.value >= 90)
    }

    @Test func healingNeverMovesToAnotherAccountOrReusesTheSameCookies() {
        let current = YTMCookieJar(header: cookieA)
        let key = current.accountKey ?? ""
        #expect(YTMHealRules.isUsable(webJar: YTMCookieJar(header: cookieA + "; X=1"), expectedAccountKey: key, currentJar: current))
        #expect(!YTMHealRules.isUsable(webJar: YTMCookieJar(header: cookieA), expectedAccountKey: key, currentJar: current))
        #expect(!YTMHealRules.isUsable(webJar: YTMCookieJar(header: cookieB), expectedAccountKey: key, currentJar: current))
        #expect(!YTMHealRules.isUsable(webJar: YTMCookieJar(header: "SID=x"), expectedAccountKey: key, currentJar: current))
    }
}

// MARK: comments

@Suite struct YouTubeCommentsTests {
    private let fixture = #"""
    {"frameworkUpdates":{"entityBatchUpdate":{"mutations":[
     {"entityKey":"ck1","payload":{"commentEntityPayload":{"properties":{"commentId":"C1","content":{"content":"Nice 1:23 part"},"publishedTime":"2 days ago","replyLevel":0},
       "author":{"displayName":"Bob","channelId":"UCbob","avatarThumbnailUrl":"https://a","isVerified":true,"isCurrentUser":false,"isCreator":false,"isArtist":true},
       "toolbar":{"likeCountLiked":"6","likeCountNotliked":"5","replyCount":"2"}}}},
     {"entityKey":"tk1","payload":{"engagementToolbarStateEntityPayload":{"likeState":"TOOLBAR_LIKE_STATE_LIKED","heartState":"TOOLBAR_HEART_STATE_HEARTED"}}},
     {"entityKey":"sk1","payload":{"engagementToolbarSurfaceEntityPayload":{"likeCommand":{"performCommentActionEndpoint":{"action":"LIKE_T"}},
       "unlikeCommand":{"performCommentActionEndpoint":{"action":"UNLIKE_T"}},"dislikeCommand":{"performCommentActionEndpoint":{"action":"DIS_T"}},
       "replyCommand":{"commentReplyDialogRenderer":{"replyButton":{"createReplyParams":"REPLY_P"}}}}}}
    ]}},
    "onResponseReceivedEndpoints":[{"reloadContinuationItemsCommand":{"continuationItems":[
     {"commentsHeaderRenderer":{"commentsCount":{"runs":[{"text":"1.2K"}]},
       "sortMenu":{"sortFilterSubMenuRenderer":{"subMenuItems":[{"selected":true,"continuation":{"reloadContinuationData":{"continuation":"TOP_T"}}},{"selected":false,"continuation":{"reloadContinuationData":{"continuation":"NEW_T"}}}]}},
       "createRenderer":{"commentSimpleboxRenderer":{"placeholderText":{"runs":[{"text":"Add a comment"}]},"submitButton":{"buttonRenderer":{"serviceEndpoint":{"createCommentEndpoint":{"createCommentParams":"CREATE_P"}}}}}}}},
     {"commentThreadRenderer":{"commentViewModel":{"commentViewModel":{"commentKey":"ck1","toolbarStateKey":"tk1","toolbarSurfaceKey":"sk1","commentId":"C1"}}}},
     {"commentThreadRenderer":{"commentViewModel":{"commentViewModel":{"commentKey":"missing","commentId":"C2"}}}},
     {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT_T"}}}}
    ]}}]}
    """#

    @Test func parsesThreadsVotesAndTokens() throws {
        let page = YTMCommentsParser.parse(parse(fixture), identityKey: "k1")
        #expect(page.threads.count == 1)
        let c = try #require(page.threads.first?.comment)
        #expect(c.id == "C1" && c.text == "Nice 1:23 part" && c.author.name == "Bob" && c.author.isVerified && c.author.isArtist)
        #expect(c.vote == .liked && c.isHearted && c.likeCountLiked == "6" && c.likeCountNotLiked == "5" && c.replyCount == "2")
        #expect(c.likeAction == "LIKE_T" && c.unlikeAction == "UNLIKE_T" && c.dislikeAction == "DIS_T" && c.undislikeAction == nil && c.replyParams == "REPLY_P")
        #expect(page.next == "NEXT_T" && page.identityKey == "k1" && !page.disabled)
        #expect(page.header?.countText == "1.2K" && page.header?.createParams == "CREATE_P" && page.header?.composerPlaceholder == "Add a comment")
        #expect(page.header?.sortTokens.map(\.token) == ["TOP_T", "NEW_T"] && page.header?.sortTokens.first?.selected == true)
    }

    @Test func aSignedOutSurfaceOffersNoActions() throws {
        let json = fixture.replacingOccurrences(of: #""likeCommand":{"performCommentActionEndpoint":{"action":"LIKE_T"}}"#, with: #""likeCommand":{"prepareAccountCommand":{}}"#)
        let c = try #require(YTMCommentsParser.parse(parse(json), identityKey: "guest").threads.first?.comment)
        #expect(c.likeAction == nil && c.dislikeAction == nil)
    }

    @Test func tabTokenAndDisabledState() {
        let tabs = parse(#"{"tabs":[{"tabRenderer":{"title":"Up next"}},{"tabRenderer":{"title":"Kommentare","content":{"sectionListRenderer":{"continuations":[{"reloadContinuationData":{"continuation":"TAB_T"}}]}}}}]}"#)
        #expect(YTMCommentsParser.tabToken(tabs) == "TAB_T")
        #expect(YTMCommentsParser.tabToken(parse(#"{"tabs":[{"tabRenderer":{"title":"x"}}]}"#)) == nil)
        #expect(YTMCommentsParser.parse(parse(#"{"messageRenderer":{"text":{"runs":[{"text":"Comments are turned off"}]}}}"#), identityKey: "g").disabled)
    }

    @Test func serverCommandPathsAreCheckedBeforeUse() {
        #expect(YTMCommentsParser.isSafeCommentPath("comment/create_comment"))
        #expect(YTMCommentsParser.isSafeCommentPath("comment/a/b_1"))
        #expect(!YTMCommentsParser.isSafeCommentPath("comment/Create"))
        #expect(!YTMCommentsParser.isSafeCommentPath("comment//x"))
        #expect(!YTMCommentsParser.isSafeCommentPath("browse/edit"))
        #expect(!YTMCommentsParser.isSafeCommentPath("comment/../x"))
        #expect(!YTMCommentsParser.isSafeCommentPath("comment/"))
    }

    @Test func actionResultNeedsTheSucceededStatus() {
        #expect(YTMCommentsParser.actionSucceeded(parse(#"{"actionResults":[{"status":"STATUS_SUCCEEDED"}]}"#)))
        #expect(YTMCommentsParser.actionSucceeded(parse(#"{"actionResult":{"status":"STATUS_SUCCEEDED"}}"#)))
        #expect(!YTMCommentsParser.actionSucceeded(parse(#"{"actionResults":[{"status":"STATUS_FAILED"}]}"#)))
        #expect(!YTMCommentsParser.actionSucceeded(parse("{}")))
        #expect(YTMCommentsParser.actionSucceeded(parse("{}"), statusOptional: true))
        #expect(!YTMCommentsParser.actionSucceeded(parse(#"{"error":{"code":1}}"#), statusOptional: true))
    }

    @Test func identityKeyFollowsLoginAndChannelNotRotation() {
        let a = YouTubeMusicSessionSnapshot(cookieHeader: "SAPISID=s; T=1", dataSyncID: "d")
        let b = YouTubeMusicSessionSnapshot(cookieHeader: "SAPISID=s; T=2", dataSyncID: "d")
        let c = YouTubeMusicSessionSnapshot(cookieHeader: "SAPISID=s; T=1", dataSyncID: "other")
        #expect(YTMCommentIdentity.key(a) == YTMCommentIdentity.key(b))
        #expect(YTMCommentIdentity.key(a) != YTMCommentIdentity.key(c))
        #expect(YTMCommentIdentity.key(YouTubeMusicSessionSnapshot()) == "guest")
    }

    @Test func timecodesInsideTheTrackBecomeLinks() {
        let text = "Nice 1:23 part, 1:02:03 too, 5:00 late, 12:99 odd"
        let m = YTMCommentTimecodes.matches(in: text, trackSeconds: 200)
        #expect(m.map(\.seconds) == [83])
        #expect(YTMCommentTimecodes.matches(in: text, trackSeconds: 4000).map(\.seconds) == [83, 3723, 300])
    }

    @Test func aWriteUnderAnotherIdentityIsRefusedBeforeAnythingIsSent() async {
        let t = AcctTransport { _ in reply("{}") }
        let s = YouTubeMusicSessionImpl(visitorData: "v")
        s.activate(cookieHeader: cookieA, visitorData: "v", dataSyncID: "d", pageID: nil)
        let client = YouTubeMusicClient(http: MusicHTTP(transport: t), session: s, sleep: { _ in })
        let comments = YouTubeMusicComments(client: client)
        await #expect(throws: YTMAccountError.accountChanged) { try await comments.postComment("hi", createParams: "P", identityKey: "someone-else") }
        await #expect(throws: YTMAccountError.signedOut) { try await comments.postComment("hi", createParams: "P", identityKey: "guest") }
        #expect(t.requests.isEmpty)
    }

    @Test func aPostIsSentOnceAndANetworkFailureIsUncertain() async {
        let s = YouTubeMusicSessionImpl(visitorData: "v")
        s.activate(cookieHeader: cookieA, visitorData: "v", dataSyncID: "d", pageID: nil)
        let key = YTMCommentIdentity.key(await s.snapshot())
        let t = AcctTransport { _ in reply(#"{"ok":true}"#, status: 500) }
        let client = YouTubeMusicClient(http: MusicHTTP(transport: t), session: s, sleep: { _ in })
        await #expect(throws: YTMAccountError.writeUncertain) { try await YouTubeMusicComments(client: client).postComment("hi", createParams: "P", identityKey: key) }
        #expect(t.count("/comment/create_comment") == 1)
        let b = body(t.last("/comment/create_comment"))
        #expect(b["createCommentParams"] as? String == "P" && b["commentText"] as? String == "hi")
    }
}

// MARK: manager

@Suite @MainActor struct YouTubeAccountManagerTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ytm-mgr-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Answers by path; the account menu answers per cookie, and per delegated id when the request carries one.
    private func transport(menus: [String: String] = ["sapi-a": "Ada", "sapi-b": "Bea"], list: @escaping @Sendable (String) -> String) -> AcctTransport {
        AcctTransport { r in
            let path = r.url?.path ?? ""
            let cookie = r.value(forHTTPHeaderField: "cookie") ?? ""
            let who = menus.first { cookie.contains("SAPISID=" + $0.key) }?.value ?? ""
            if path.hasSuffix("/account/account_menu") {
                let id = onBehalf(r)
                let name = who.isEmpty ? "" : (id.map { $0 == "BRAND" ? "BrandName" : who } ?? who)
                return reply(menuJSON(name: name))
            }
            if path.hasSuffix("/account/accounts_list") { return reply(list(who)) }
            return reply("{}")
        }
    }

    private func make(_ t: AcctTransport, dir: URL? = nil, secrets: YTMSecretStore = YTMMemorySecretStore()) -> (YouTubeMusicAccountManager, YouTubeMusicSessionImpl, YouTubeMusicAccountStore) {
        let session = YouTubeMusicSessionImpl(visitorData: "CgtANON")
        let provider = YouTubeMusicFullProvider(http: MusicHTTP(transport: t), session: session)
        let store = YouTubeMusicAccountStore(directory: dir ?? tempDir(), secrets: secrets)
        return (YouTubeMusicAccountManager(provider: provider, session: session, store: store, keepAlive: false), session, store)
    }

    private let oneChannel: @Sendable (String) -> String = { _ in listJSON([item(name: "Ada", tokens: sync("111||333"), selected: true)]) }
    private let twoChannels: @Sendable (String) -> String = { _ in
        listJSON([item(name: "Ada", tokens: sync("111||333"), selected: true), item(name: "Brand", tokens: pageTok("BRAND"))])
    }

    @Test func singleChannelSignInPersistsAndActivates() async throws {
        let t = transport(list: oneChannel)
        let (m, session, store) = make(t)
        let outcome = try await m.signIn(cookieHeader: cookieA)
        guard case .signedIn(let acct) = outcome else { Issue.record("expected signed in"); return }
        #expect(acct.name == "Ada" && acct.isActive && !acct.selectionPending)
        #expect(m.isSignedIn && m.accounts.count == 1 && m.epoch == 1)
        let snap = await session.snapshot()
        #expect(snap.isSignedIn && snap.dataSyncID == "111" && snap.visitorData == "CgtLOGIN")
        #expect(store.cookie(for: acct.id)?.contains("SAPISID=sapi-a") == true && store.activeID == acct.id)
        #expect(store.visitorData(for: acct.id) == "CgtLOGIN")
    }

    @Test func aCookieThatDoesNotAuthenticateRollsBack() async {
        let t = transport(menus: [:], list: oneChannel)
        let (m, session, store) = make(t)
        await #expect(throws: YTMAccountError.notAuthenticated) { try await m.signIn(cookieHeader: cookieA) }
        #expect(!session.isSignedIn && store.list().isEmpty && m.active == nil && m.epoch == 0)
        #expect(await session.snapshot().visitorData == "CgtANON")
    }

    @Test func aCookieWithoutALoginValueNeverReachesTheNetwork() async {
        let t = transport(list: oneChannel)
        let (m, _, _) = make(t)
        await #expect(throws: YTMAccountError.signInIncomplete) { try await m.signIn(cookieHeader: "SID=1") }
        #expect(t.requests.isEmpty)
    }

    @Test func severalChannelsWaitForAPickAndTheAccountIsNotUsableMeanwhile() async throws {
        let t = transport(list: twoChannels)
        let (m, session, store) = make(t)
        let outcome = try await m.signIn(cookieHeader: cookieA)
        #expect(outcome == .selectionRequired)
        #expect(m.selectionRequired && !m.isSignedIn && m.pickerMode == .required)
        #expect(await session.snapshot().cookieHeader == nil)
        #expect(store.active?.selectionPending == true)

        let rows = try await m.channels()
        #expect(rows.count == 2 && !rows.contains { $0.isSelected })
        #expect(session.current.held)   // restored to held after the list call
        let brand = try #require(rows.first { $0.id == "BRAND" })
        try await m.selectChannel(key: brand.selectionKey)
        #expect(m.isSignedIn && !m.selectionRequired && m.pickerMode == nil)
        let snap = await session.snapshot()
        #expect(snap.dataSyncID == "BRAND" && snap.pageID == "BRAND" && snap.isSignedIn)
        #expect(m.notice == "Signed in as BrandName")
        #expect(t.requests.contains { onBehalf($0) == "BRAND" })
    }

    @Test func aChannelThatIsGoneIsReportedAndNothingChanges() async throws {
        let (m, session, _) = make(transport(list: twoChannels))
        _ = try await m.signIn(cookieHeader: cookieA)
        await #expect(throws: YTMAccountError.channelUnavailable) { try await m.selectChannel(key: "nope") }
        #expect(m.selectionRequired && session.current.held)
    }

    @Test func switchingAccountsAndRollingBackOnFailure() async throws {
        let t = transport(list: oneChannel)
        let (m, session, store) = make(t)
        _ = try await m.signIn(cookieHeader: cookieA)
        _ = try await m.signIn(cookieHeader: cookieB)
        #expect(m.accounts.map(\.name).count == 2 && m.active?.name == "Bea")
        let idA = try #require(YouTubeMusicAccountStore.accountID(forCookieHeader: cookieA))
        let idB = try #require(YouTubeMusicAccountStore.accountID(forCookieHeader: cookieB))
        #expect(m.accounts.map(\.id) == [idA, idB])   // oldest first, the second sign-in did not reorder
        let epoch = m.epoch
        try await m.switchAccount(to: idA)
        #expect(m.active?.id == idA && session.activeAccountKey == idA && m.epoch == epoch + 1)

        // The saved session of B has died: the switch fails and A stays in place.
        store.updateCookie(id: idB, header: "SID=x; SAPISID=dead")
        await #expect(throws: YTMAccountError.accountSessionExpired) { try await m.switchAccount(to: idB) }
        #expect(m.active?.id == idA && session.activeAccountKey == idA && store.activeID == idA)
    }

    @Test func signOutKeepsSavedAccountsAndRemoveDeletesThem() async throws {
        let secrets = YTMMemorySecretStore()
        let (m, session, store) = make(transport(list: oneChannel), secrets: secrets)
        _ = try await m.signIn(cookieHeader: cookieA)
        let id = try #require(m.active?.id)
        m.signOut()
        #expect(m.active == nil && !session.isSignedIn && store.activeID == nil && m.accounts.count == 1)
        #expect(await session.snapshot().cookieHeader == nil)
        m.remove(id)
        #expect(m.accounts.isEmpty && secrets.keys.isEmpty)
    }

    @Test func removingTheActiveAccountSignsOut() async throws {
        let (m, session, _) = make(transport(list: oneChannel))
        _ = try await m.signIn(cookieHeader: cookieA)
        m.remove(try #require(m.active?.id))
        #expect(m.active == nil && !session.isSignedIn)
    }

    @Test func relaunchRestoresTheActiveAccountWithoutTheNetwork() async throws {
        let dir = tempDir(), secrets = YTMMemorySecretStore()
        let (m1, _, _) = make(transport(list: oneChannel), dir: dir, secrets: secrets)
        _ = try await m1.signIn(cookieHeader: cookieA)
        let t2 = transport(list: oneChannel)
        let (m2, session2, _) = make(t2, dir: dir, secrets: secrets)
        #expect(m2.active?.name == "Ada" && session2.isSignedIn)
        #expect((await session2.snapshot()).dataSyncID == "111")
        #expect(t2.requests.isEmpty)
    }

    @Test func aPendingPickReopensAfterARestart() async throws {
        let dir = tempDir(), secrets = YTMMemorySecretStore()
        let (m1, _, _) = make(transport(list: twoChannels), dir: dir, secrets: secrets)
        _ = try await m1.signIn(cookieHeader: cookieA)
        let (m2, session2, _) = make(transport(list: twoChannels), dir: dir, secrets: secrets)
        #expect(m2.selectionRequired && m2.pickerMode == .required && !session2.isSignedIn)
    }

    @Test func cancellingAPendingSignInRemovesTheHalfFinishedAccount() async throws {
        let (m, session, store) = make(transport(list: twoChannels))
        _ = try await m.signIn(cookieHeader: cookieA)
        m.cancelPendingSignIn()
        #expect(store.list().isEmpty && !session.isSignedIn && !m.selectionRequired && m.pickerMode == nil)
    }

    @Test func keepAliveRefreshesTheVisitorAndSkipsWhenTheAccountChanged() async throws {
        let t = transport(list: oneChannel)
        let (m, session, store) = make(t)
        _ = try await m.signIn(cookieHeader: cookieA)
        let before = t.count("/account/account_menu")
        await m.keepAliveOnce(heal: false)
        #expect(t.count("/account/account_menu") == before + 1)
        m.signOut()
        let after = t.count("/account/account_menu")
        await m.keepAliveOnce(heal: false)
        #expect(t.count("/account/account_menu") == after)
        #expect(!session.isSignedIn && store.list().count == 1)
    }

    @Test func aRejectedRequestWaitsForOneHealThenRetriesOnce() async throws {
        let t = transport(list: oneChannel)
        let (m, _, _) = make(t)
        _ = try await m.signIn(cookieHeader: cookieA)
        let heals = Box(0)
        m.refreshProvider = { _, _ in heals.value += 1; return nil }
        let calls = Box(0)
        await #expect(throws: YTMAccountError.sessionExpired) {
            _ = try await m.run { () async throws -> Int in calls.value += 1; throw MusicError.notSignedIn("x") }
        }
        #expect(calls.value == 2 && heals.value == 1)
        // The second rejection inside the cooldown does not start another heal.
        await #expect(throws: YTMAccountError.sessionExpired) {
            _ = try await m.run { () async throws -> Int in throw MusicError.notSignedIn("x") }
        }
        #expect(heals.value == 1)
    }

    @Test func aHealThatRecoversLetsTheRetrySucceed() async throws {
        let t = transport(list: oneChannel)
        let (m, session, _) = make(t)
        _ = try await m.signIn(cookieHeader: cookieA)
        let key = try #require(session.activeAccountKey)
        m.refreshProvider = { k, _ in k == key ? cookieA + "; __Secure-1PSIDTS=fresh" : nil }
        let calls = Box(0)
        let value = try await m.run { () async throws -> Int in
            calls.value += 1
            if calls.value == 1 { throw MusicError.notSignedIn("x") }
            return 7
        }
        #expect(value == 7)
        #expect(session.jar?.header.contains("__Secure-1PSIDTS=fresh") == true)
    }

    @Test func aHealForTheWrongAccountIsRefused() async throws {
        let t = transport(list: oneChannel)
        let (m, session, _) = make(t)
        _ = try await m.signIn(cookieHeader: cookieA)
        let before = session.jar?.header
        await #expect(throws: YTMAccountError.accountChanged) { try await m.signIn(cookieHeader: cookieB, expectAccount: session.activeAccountKey) }
        #expect(session.jar?.header == before)
    }
}

// MARK: library source switcher

@Suite struct MusicLibrarySourceTests {
    private func acct(_ id: String, pending: Bool = false) -> YTMAccountSummary {
        YTMAccountSummary(id: id, name: "n", subtitle: nil, thumbnail: nil, isActive: true, selectionPending: pending, hasMultipleChannels: false)
    }

    @Test func signedOutOffersOnlyLocal() {
        #expect(MusicLibrarySources.available(youTubeAccount: nil, spotifySignedIn: false) == [.local])
        #expect(MusicLibrarySource.local.playlistsTitle == "Your playlists")
    }

    @Test func signedInAccountsAreOffered() {
        let o = MusicLibrarySources.available(youTubeAccount: acct("ga-1"), spotifySignedIn: true)
        #expect(o == [.local, .youTubeMusic(accountID: "ga-1"), .spotify])
        #expect(MusicLibrarySources.available(youTubeAccount: acct("ga-1", pending: true), spotifySignedIn: false) == [.local])
    }

    @Test func aRememberedSourceThatIsGoneFallsBackToLocal() {
        let o = MusicLibrarySources.available(youTubeAccount: acct("ga-2"), spotifySignedIn: false)
        #expect(MusicLibrarySources.resolve(saved: .youTubeMusic(accountID: "ga-1"), available: o) == .local)
        #expect(MusicLibrarySources.resolve(saved: .youTubeMusic(accountID: "ga-2"), available: o) == .youTubeMusic(accountID: "ga-2"))
        #expect(MusicLibrarySources.resolve(saved: nil, available: o) == .local)
    }

    @Test func choicesPersistAndSignedOutKeepsEverythingLocal() throws {
        let suite = try #require(UserDefaults(suiteName: "ytm.source.test." + UUID().uuidString))
        let store = MusicLibrarySourceStore(defaults: suite)
        #expect(store.source == nil && store.policy == MusicPlacementPolicy())
        store.source = .youTubeMusic(accountID: "ga-9")
        store.policy = MusicPlacementPolicy(likes: .account, playlists: .account)
        #expect(MusicLibrarySourceStore(defaults: suite).source == .youTubeMusic(accountID: "ga-9"))
        let p = MusicLibrarySourceStore(defaults: suite).policy
        #expect(p.likes == .account && p.resolved(accountAvailable: false) == MusicPlacementPolicy())
        #expect(p.resolved(accountAvailable: true) == p)
    }
}
