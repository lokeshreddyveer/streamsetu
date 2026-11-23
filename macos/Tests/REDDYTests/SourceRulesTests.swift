import Testing
import Foundation
@testable import REDDY

/// Rules about the source tree itself, and the picture-tile pieces that are pure logic.
@Suite("Source rules") struct SourceRulesTests {
    private static var sourcesRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY") }

    private func swiftFiles(under sub: String = "") -> [URL] {
        let root = Self.sourcesRoot.appendingPathComponent(sub)
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (en?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Anything that sends a request goes through the app's own client (proxy, network settings), never the system's shared session. Nothing is allowed to be an exception today.
    static let sharedSessionAllowList: Set<String> = []

    /// Every folder header (Movies, Series, Live TV; iPhone, iPad, Mac) is drawn by FolderHeaderLabel: nobody prints a folder's display name or count by hand.
    @Test func folderHeadersAllGoThroughTheSharedLabel() throws {
        let iosRoot = Self.sourcesRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/StreamSetu")
        var files = [Self.sourcesRoot.appendingPathComponent("Features/Movies/Views/FolderRowsSection.swift")]
        if FileManager.default.fileExists(atPath: iosRoot.path) { files.append(iosRoot.appendingPathComponent("Screens/FolderRowsView.swift")) }
        var offenders: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(text.contains("FolderHeaderLabel("), "\(f.lastPathComponent) must draw its folder header with FolderHeaderLabel")
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("Text(row.display)") || line.contains("row.countText") || line.contains("row.count.formatted()") || line.contains("\\(row.display) ·") { offenders.append("\(f.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(offenders.isEmpty, "folder name or count printed by hand at \(offenders)")
    }

    /// The Mac Live TV is the plain channel column: no Folders/List switch, no folders mode.
    @Test func macLiveTVHasNoFoldersMode() throws {
        let dir = Self.sourcesRoot.appendingPathComponent("Features/LiveTV")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Views/LiveFolderColumn.swift").path))
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let f as URL in en! where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for bad in ["FolderViewMode", "LiveFolderColumn", "FolderRowsModel", "Folders or channel list", "showsFolders"] {
                #expect(!text.contains(bad), "\(f.lastPathComponent) mentions \(bad)")
            }
        }
    }

    /// The sidebar's Live TV folder list is separate from the screen: it still builds, and selecting a folder makes the screen list that folder's channels.
    @Test @MainActor func sidebarLiveTVFolderListStillBuildsAndSelects() {
        let sid = UUID()
        let cats = [CatalogCategory(id: "c1", sourceID: sid, kind: .channel, providerID: "1", name: "News", sortOrder: 0, itemCount: 4),
                    CatalogCategory(id: "c2", sourceID: sid, kind: .channel, providerID: "2", name: "Sports", sortOrder: 1, itemCount: 2)]
        let entries = SidebarModel.folders(cats)
        #expect(SidebarModel.categoryKind(for: .liveTV) == .channel)
        #expect(entries.map(\.title) == ["News", "Sports"] && entries.map(\.count) == [4, 2])
        let router = AppRouter()
        router.navigate(.liveTV)
        router.select(entries[1].selection)
        #expect(router.selection == .folder("c2"))
        #expect(LiveFilter(router.selection) == .category("c2"))
    }

    @Test func noCodePathUsesTheSystemSharedSession() throws {
        var offenders: [String] = []
        for f in swiftFiles() {
            let name = f.lastPathComponent
            guard !Self.sharedSessionAllowList.contains(name) else { continue }
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains("URLSession.shared") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(name):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, "URLSession.shared at \(offenders)")
    }

    @Test func lowerLayersDoNotImportSwiftUI() throws {
        var offenders: [String] = []
        for layer in ["Domain", "Data", "Services", "Playback", "Security"] {
            for f in swiftFiles(under: layer) {
                let text = try String(contentsOf: f, encoding: .utf8)
                if text.split(separator: "\n").contains(where: { $0 == "import SwiftUI" }) { offenders.append(f.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func aPictureThatCannotBeFoundIsNotAskedForAgainButAPassingFailureIs() {
        #expect(ImageCache.isPermanent(NetworkError.http(status: 404, retryAfter: nil)))
        #expect(ImageCache.isPermanent(NetworkError.http(status: 403, retryAfter: nil)))
        #expect(!ImageCache.isPermanent(NetworkError.http(status: 503, retryAfter: nil)))
        #expect(!ImageCache.isPermanent(NetworkError.http(status: 429, retryAfter: nil)))
        #expect(!ImageCache.isPermanent(NetworkError.offline) && !ImageCache.isPermanent(NetworkError.timeout))
        #expect(CachePolicy.default.retryDelays.count == 2 && CachePolicy.default.retryDelays.allSatisfy { $0 < 3 })
    }

    @Test func theTileForATitleWithoutAPosterIsStableAndDescribesTheTitle() {
        let a = ArtworkTile.Content(title: "Alien: Romulus", detail: nil), b = ArtworkTile.Content(title: "alien: romulus", detail: "2024")
        #expect(a.hue == b.hue && a.hue >= 0 && a.hue < 360, "the same title always gets the same colour")
        #expect(ArtworkTile.Content.detail(year: 2024, quality: "4K") == "2024 · 4K")
        #expect(ArtworkTile.Content.detail(year: nil, quality: "Series") == "Series")
        #expect(ArtworkTile.Content.detail(year: nil, quality: nil) == nil)
    }
}

@Suite("Network rules") struct NetworkRulesTests {
    @Test func aRedirectToAnotherHostDropsTheApiKeyAndBasicLoginSetAsPlainHeaders() {
        let session = URLSession(configuration: .ephemeral)
        var first = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/subtitles")!)
        first.setValue("key-123", forHTTPHeaderField: "Api-Key"); first.setValue("Basic dXNlcjpwdw==", forHTTPHeaderField: "Authorization"); first.setValue("StreamSetu v1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: first)
        var next = URLRequest(url: URL(string: "https://elsewhere.example/file.srt")!)
        next.allHTTPHeaderFields = first.allHTTPHeaderFields
        let response = HTTPURLResponse(url: first.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var out: URLRequest?
        RedirectCredentialGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) { out = $0 }
        #expect(out?.value(forHTTPHeaderField: "Api-Key") == nil && out?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(out?.value(forHTTPHeaderField: "User-Agent") == "StreamSetu v1")
        var same = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/other")!); same.allHTTPHeaderFields = first.allHTTPHeaderFields
        RedirectCredentialGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: same) { out = $0 }
        #expect(out?.value(forHTTPHeaderField: "Api-Key") == "key-123", "the same server keeps what it was sent")
        session.invalidateAndCancel()
    }

    @Test func aStalledHostCannotHoldEveryDownloadSlot() async throws {
        var p = CachePolicy.default; p.maxConcurrentDownloads = 4; p.maxPerHost = 2
        let cache = ImageCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("slots-\(UUID().uuidString)"), policy: p, http: HTTPClient())
        await cache.acquire(host: "slow.example"); await cache.acquire(host: "slow.example")
        let third = Task { await cache.acquire(host: "slow.example"); return true }          // waits: the host is at its limit
        try await Task.sleep(nanoseconds: 50_000_000)
        await cache.acquire(host: "other.example")           // another host is not held up
        await cache.release(host: "slow.example")
        #expect(await third.value, "a freed slot goes to the waiting request of the same host")
    }
}

@Suite("Stalker gating") @MainActor struct StalkerGatingTests {
    @Test func theStoreBuildNeverDetectsOrOffersAStalkerPortal() {
        let link = "http://portal.example:8080/c/"
        #expect(SourceDetector.detect(link, allowStalker: true)?.kind == .stalker, "other builds keep it")
        #expect(SourceDetector.detect(link, allowStalker: false)?.kind == .m3uURL, "the store build treats it as an ordinary link")
        #expect(!AddSourceKind.offered(stalker: false).contains(.stalker) && AddSourceKind.offered(stalker: true).contains(.stalker))
        let off = AddSourceViewModel(); off.paste(link, allowStalker: false)
        #expect(off.kind != .stalker)
        let on = AddSourceViewModel(); on.paste(link, allowStalker: true)
        #expect(on.kind == .stalker)
        let forced = AddSourceViewModel(); forced.allowStalker = false; forced.kind = .stalker; forced.server = "http://p.example"; forced.username = "00:1A:79:00:00:01"
        #expect(!forced.canSubmit, "even a form switched to Stalker by other means cannot be added")
        forced.allowStalker = true
        #expect(forced.canSubmit)
    }

    @Test func theBuildFlagDecidesTheDefault() {
        #if STREAMSETU_APPSTORE
        #expect(!SourceDetector.stalkerOffered)
        #else
        #expect(SourceDetector.stalkerOffered)
        #endif
    }
}

@Suite("Launch migration cost") struct LaunchMigrationCostTests {
    @Test func theLaunchMigrationDoesNotTouchOrIndexTheBigTables() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-mig-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try Connection(path: path, readOnly: false)
        try conn.exec("PRAGMA foreign_keys=ON")
        for m in DatabaseMigrator.migrations where m.version <= 18 { try conn.exec(m.sql); try conn.exec("PRAGMA user_version = \(m.version)") }
        try conn.exec("INSERT INTO sources(id, name, type, base_url, created_at) VALUES('s1','Big','m3uRemote','http://x',1)")
        try conn.exec("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 169000)
            INSERT INTO movies(id, source_id, provider_id, title, normalized_title, stream_ref, created_at, updated_at, last_seen_at, category_id, category_name, release_year)
            SELECT 's1|movie|' || i, 's1', i, 'Film ' || i, 'film ' || i, i || '.mp4', 1, 1, 1, 'c' || (i % 200), 'Cat', 1990 + (i % 35) FROM n
            """)
        let start = DispatchTime.now()
        try DatabaseMigrator.migrate(conn)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        print("MIGRATION v19+v20 on 169,000 movie rows: \(Int(ms)) ms")
        #expect(try conn.scalarInt("SELECT COUNT(*) FROM movies") == 169_000)
        #expect(ms < 500, "measured \(ms) ms: no index is built and no row is read at launch")
        let t2 = DispatchTime.now()
        SchemaV19.ensureQueryIndexes(db: try DatabaseManager(path: path))
        print("BACKGROUND index build on the same rows: \(Int(Double(DispatchTime.now().uptimeNanoseconds - t2.uptimeNanoseconds) / 1e6)) ms")
    }
}
