import Foundation
@testable import REDDY

enum TestSupport {
    static func makeDB() throws -> DatabaseManager {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reddy-test-\(UUID().uuidString).sqlite").path
        return try DatabaseManager(path: path)
    }

    static func makeSource(_ db: DatabaseManager, name: String = "Test", type: SourceType = .m3uRemote) throws -> PlaylistSource {
        let s = PlaylistSource(name: name, type: type, baseURL: "http://example.com/p.m3u")
        try SQLiteCatalogRepository(db: db).save(source: s)
        return s
    }

    static func channel(_ s: PlaylistSource, _ pid: String, _ name: String, cat: String? = "News", order: Int = 0, epg: String? = nil) -> Channel {
        let norm = MetadataNormalizer.normalize(name)
        return Channel(id: ItemID.make(source: s.id, kind: .channel, provider: pid), sourceID: s.id, providerID: pid, name: name,
                       normalizedName: norm, categoryID: cat.map { "cat-\($0)" }, categoryName: cat, logoURL: nil, epgID: epg, language: nil,
                       country: nil, resolutionHint: MetadataNormalizer.qualityLabel(norm), sortOrder: order, streamRef: "http://x/\(pid).ts", groupKey: nil)
    }

    static func movie(_ s: PlaylistSource, _ pid: String, _ title: String, year: Int? = nil) -> Movie {
        Movie(id: ItemID.make(source: s.id, kind: .movie, provider: pid), sourceID: s.id, providerID: pid, title: title,
              normalizedTitle: MetadataNormalizer.normalize(title), overview: nil, posterURL: nil, backdropURL: nil, releaseYear: year,
              durationSeconds: nil, genre: nil, rating: nil, categoryID: nil, categoryName: "Action", streamRef: "\(pid).mp4", addedAt: nil, detailFetchedAt: nil)
    }

    static func series(_ s: PlaylistSource, _ pid: String, _ title: String) -> Series {
        Series(id: ItemID.make(source: s.id, kind: .series, provider: pid), sourceID: s.id, providerID: pid, title: title,
               normalizedTitle: MetadataNormalizer.normalize(title), overview: nil, posterURL: nil, backdropURL: nil, genre: nil,
               releaseYear: nil, rating: nil, categoryID: nil, categoryName: "Drama", addedAt: nil, lastMetadataRefresh: nil)
    }
}
