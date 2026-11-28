import Foundation
import SwiftUI
import AppKit
@testable import REDDY

// Deterministic fixtures for the responsive snapshot harness: a hub on a throwaway folder, a sample catalogue that answers instantly,
// mixed-script titles and flat-colour artwork written to disk (file addresses, so nothing touches the network).
// Fixture and label colours live here and nowhere else in the harness.

enum MusicSnapshotStyle {
    /// Accents the harness cycles through (name, colour).
    static let accents: [(name: String, color: Color)] = [
        ("coral", Color(red: 0.96, green: 0.42, blue: 0.36)),
        ("teal", Color(red: 0.16, green: 0.72, blue: 0.80)),
    ]
    static func accent(named name: String?) -> Color? { accents.first { $0.name == name }?.color }

    /// Contact-sheet drawing.
    static let sheetBackground = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let sheetText = NSColor(calibratedWhite: 0.92, alpha: 1)
    static let sheetFailure = NSColor(calibratedRed: 1, green: 0.35, blue: 0.3, alpha: 1)
    static var sheetFont: NSFont { NSFont.systemFont(ofSize: 15, weight: .semibold) }

    /// Flat artwork swatches (RGB, 0...1).
    static let swatches: [(Double, Double, Double)] = [
        (0.85, 0.30, 0.30), (0.95, 0.65, 0.20), (0.35, 0.70, 0.40), (0.25, 0.60, 0.85),
        (0.55, 0.40, 0.85), (0.90, 0.45, 0.70), (0.30, 0.75, 0.75), (0.60, 0.60, 0.65),
    ]
}

/// Plain values for the sample catalogue (Sendable, so the provider can hold them).
struct MusicSnapshotData: Sendable {
    var tracks: [MusicTrack]
    var artists: [MusicArtist]
    var albums: [MusicAlbum]
    var playlists: [MusicPlaylist]
    var genres: [MusicBrowseGenre]

    static let providerID = "sample"

    /// Titles in English, Telugu, Hindi, Tamil, Korean, Japanese and Arabic, a few very long ones and a few that mix scripts.
    static let titles: [String] = [
        "Midnight City Lights", "Paper Planes Over the Bay", "Golden Hour", "Quiet Rivers",
        "రాత్రి వెన్నెల", "నా ప్రాణం నీవే", "ఆకాశం నీ హద్దు", "చిన్ని చిన్ని ఆశలు",
        "तेरे बिना ज़िंदगी", "दिल की बात सुनो", "बारिश की पहली बूँद", "सपनों का सफ़र",
        "நிலா காலம்", "என் உயிரே", "மழை வருமா", "வானம் எல்லை",
        "봄날의 기억", "너의 이름은", "별이 빛나는 밤", "한강의 노래",
        "夜明けの歌", "桜の下で", "君の声が聞こえる", "海の向こうへ",
        "ليلة القمر", "حبيبي يا نور العين", "صباح الخير يا وطني", "أغنية الصحراء",
        "A Very Long Title That Keeps Going and Going Until It Has to Be Shortened (feat. Several Different Artists) [Extended Anniversary Remaster 2024]",
        "The Unbelievably Detailed Story of a Small Town and Its River, Part Two: The Return of the Lanterns (Live at the Old Theatre)",
        "Chandni रात (చంద్రుడు) – 月光 Remix", "Tum Hi Ho × నువ్వే నువ్వే × 너만 있으면",
        "Café del Mar Interlude", "Naïve Étude No. 3 – Largo", "Ångström Waltz", "Sunrise (Reprise)",
        "Echoes", "Lantern Season", "Salt and Stone", "Last Train Home",
    ]

    static let artistNames: [String] = [
        "Aria Lowell", "రవి తేజ", "अनन्या शर्मा", "கார்த்திக் ராஜா", "김하늘", "田中 葵", "فيروز الليل", "The Long Winter Collective of Wandering Musicians",
        "Mira & the Tides", "Oskar Lind", "Zoë Marchetti", "Night Owls",
    ]

    static let albumTitles: [String] = [
        "Harbour Lights", "వెన్నెల రాగాలు", "सुरों का सफ़र", "மழை நேரம்", "봄의 노래", "夜の旋律", "ليالي الصيف", "An Extremely Long Album Title for Layout Testing Purposes (Deluxe Edition)",
    ]

    /// Builds the data and writes the flat-colour artwork files into `dir`.
    static func make(artworkDirectory dir: URL) -> MusicSnapshotData {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var covers: [MusicThumbnail] = []
        for (i, c) in MusicSnapshotStyle.swatches.enumerated() {
            let url = dir.appendingPathComponent("cover-\(i).png")
            if let png = solidPNG(r: c.0, g: c.1, b: c.2, side: 256) { try? png.write(to: url) }
            covers.append(MusicThumbnail(url: url.absoluteString, width: 256, height: 256))
        }
        func cover(_ i: Int) -> [MusicThumbnail] { [covers[i % covers.count]] }

        let artists = artistNames.enumerated().map { i, n in
            MusicArtist(id: "ar\(i)", providerID: providerID, name: n, thumbnails: i % 5 == 4 ? [] : cover(i),
                        genres: ["Pop", "Folk"], followers: 1_000 + i * 3_700, bio: "A short fixture biography for \(n). It exists so the layout has a line of text to wrap.")
        }
        let albums = albumTitles.enumerated().map { i, t in
            MusicAlbum(id: "al\(i)", providerID: providerID, title: t,
                       artists: [MusicArtistRef(id: artists[i % artists.count].id, name: artists[i % artists.count].name)],
                       thumbnails: i % 4 == 3 ? [] : cover(i + 2), releaseDate: "20\(10 + i)-0\(1 + i % 9)-15", totalTracks: 8 + i, albumType: "album")
        }
        let tracks = titles.enumerated().map { i, t -> MusicTrack in
            let a = artists[i % artists.count], al = albums[i % albums.count]
            return MusicTrack(id: "t\(i)", providerID: providerID, title: t, durationMs: Int64(150_000 + i * 7_321), trackNumber: i % 12 + 1,
                              artists: [MusicArtistRef(id: a.id, name: a.name)],
                              album: MusicAlbumRef(id: al.id, title: al.title, artists: al.artists, thumbnails: al.thumbnails, releaseDate: al.releaseDate, totalTracks: al.totalTracks),
                              thumbnails: i % 5 == 2 ? [] : cover(i), explicit: i % 9 == 0)
        }
        let playlistNames = ["Morning Drive", "తెలుగు హిట్స్", "शाम की चाय", "Late Night Focus With an Unusually Long Playlist Name"]
        let playlists = playlistNames.enumerated().map { i, n in
            MusicPlaylist(id: "pl\(i)", providerID: providerID, name: n, summary: "A fixture playlist of \(10 + i * 3) songs.", owner: "Sample",
                          thumbnails: cover(i + 4), trackCount: 10 + i * 3)
        }
        let genres = ["Pop", "Rock", "Folk", "Classical", "Dance", "Jazz"].enumerated().map { MusicBrowseGenre(id: "g\($0.offset)", name: $0.element, thumbnails: []) }
        return MusicSnapshotData(tracks: tracks, artists: artists, albums: albums, playlists: playlists, genres: genres)
    }

    private static func solidPNG(r: Double, g: Double, b: Double, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let data = rep.bitmapData else { return nil }
        for y in 0..<side {
            for x in 0..<side {
                // A soft diagonal so a stretched or cropped cover is visible in the screenshot.
                let k = 0.85 + 0.15 * Double(x + y) / Double(2 * side)
                let o = y * rep.bytesPerRow + x * 4
                data[o] = UInt8(min(255, r * k * 255)); data[o + 1] = UInt8(min(255, g * k * 255)); data[o + 2] = UInt8(min(255, b * k * 255)); data[o + 3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A metadata source that answers from `MusicSnapshotData` at once. No network.
struct MusicSnapshotCatalogue: MusicMetadataProvider {
    var info = MusicProviderInfo(id: MusicSnapshotData.providerID, name: "Sample catalogue", summary: "Fixture data for layout checks.")
    var capabilities: MusicCapabilities { .metadata }
    let data: MusicSnapshotData
    /// Set for the discovery stand-ins: the scope the lists report (the chosen country's own chart, or a worldwide one).
    var discoveryScope: MusicSectionScope?
    init(data: MusicSnapshotData, id: String? = nil, name: String? = nil, scope: MusicSectionScope? = nil) {
        self.data = data; discoveryScope = scope
        if let id { info = MusicProviderInfo(id: id, name: name ?? id, summary: "Fixture data for layout checks.") }
    }

    func searchTracks(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { MusicPage(items: Array(data.tracks.prefix(14))) }
    func searchArtists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicArtist> { MusicPage(items: Array(data.artists.prefix(8))) }
    func searchAlbums(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { MusicPage(items: Array(data.albums.prefix(8))) }
    func searchPlaylists(_ query: String, page: MusicPagination?) async throws -> MusicPage<MusicPlaylist> { MusicPage(items: data.playlists) }

    func featured() async throws -> [MusicBrowseSection] {
        if let scope = discoveryScope {
            let global = scope == .global
            return [MusicBrowseSection(id: info.id + "-songs", title: global ? "Top songs worldwide" : "Top songs", items: data.tracks.prefix(10).map { .track($0) }, scope: scope),
                    MusicBrowseSection(id: info.id + "-albums", title: global ? "Top albums worldwide" : "Top albums", items: data.albums.map { .album($0) }, scope: scope)]
        }
        return [MusicBrowseSection(id: "mix", title: "Made for you", items: data.playlists.map { .playlist($0) }),
         MusicBrowseSection(id: "new", title: "New releases", items: data.albums.map { .album($0) }),
         MusicBrowseSection(id: "hot", title: "Trending songs", items: data.tracks.prefix(10).map { .track($0) }),
         MusicBrowseSection(id: "art", title: "Artists to follow", items: data.artists.map { .artist($0) })]
    }
    func genres() async throws -> [MusicBrowseGenre] { data.genres }
    func track(id: String) async throws -> MusicTrack { try data.tracks.first { $0.id == id }.orThrow() }

    func album(id: String) async throws -> MusicAlbum { try data.albums.first { $0.id == id }.orThrow() }
    func albumTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> {
        MusicPage(items: data.tracks.filter { $0.album?.id == id } + data.tracks.prefix(6))
    }
    func artist(id: String) async throws -> MusicArtist { try data.artists.first { $0.id == id }.orThrow() }
    func artistTopTracks(id: String) async throws -> [MusicTrack] { Array(data.tracks.prefix(10)) }
    func artistAlbums(id: String, page: MusicPagination?) async throws -> MusicPage<MusicAlbum> { MusicPage(items: data.albums) }
    func relatedArtists(id: String) async throws -> [MusicArtist] { Array(data.artists.prefix(6)) }
    func playlist(id: String) async throws -> MusicPlaylist { try data.playlists.first { $0.id == id }.orThrow() }
    func playlistTracks(id: String, page: MusicPagination?) async throws -> MusicPage<MusicTrack> { MusicPage(items: Array(data.tracks.prefix(24))) }
}

private extension Optional {
    func orThrow() throws -> Wrapped {
        guard let self else { throw MusicError.unsupported("fixture item") }
        return self
    }
}

/// The hub, its library and the sample data, all on a throwaway folder and an unnamed defaults suite.
@MainActor
final class MusicSnapshotWorld {
    let directory: URL
    let hub: MusicHub
    let data: MusicSnapshotData
    let localPlaylistID: UUID
    private let suite: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("music-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
        suite = "music.snapshot.\(UUID().uuidString)"
        let defaults = try requiredValue(UserDefaults(suiteName: suite))
        data = MusicSnapshotData.make(artworkDirectory: root.appendingPathComponent("Art", isDirectory: true))
        hub = MusicHub(directory: root.appendingPathComponent("Hub", isDirectory: true), defaults: defaults)
        let hub = hub, data = data

        // One source only: the sample catalogue.
        for p in hub.registry.all { hub.registry.setEnabled(false, id: p.id, reason: .setup) }
        hub.registry.register(MusicSnapshotCatalogue(data: data))
        hub.registry.setEnabled(true, id: MusicSnapshotData.providerID, reason: .setup)
        hub.registry.setActiveMetadata(MusicSnapshotData.providerID)

        let lib = hub.library
        lib.settings.consentDone = true
        for t in data.tracks.prefix(18) { lib.toggleLike(t) }
        for (i, t) in data.tracks.prefix(12).enumerated() { lib.recordPlay(t, playedMs: Int64(60_000 + i * 9_000)) }
        for a in data.artists.prefix(5) { lib.toggleFollow(a) }
        for a in data.albums.prefix(4) { lib.toggleSave(a) }
        let first = lib.createPlaylist(name: "Road trip", tracks: Array(data.tracks.prefix(9)))
        lib.createPlaylist(name: "రాత్రి నిద్ర", tracks: Array(data.tracks.dropFirst(10).prefix(7)))
        lib.createPlaylist(name: "A playlist with an extremely long name that has to be shortened somewhere sensible", tracks: Array(data.tracks.dropFirst(20).prefix(5)))
        localPlaylistID = first.id

        // A queue with a playing track, paused or playing, without starting any audio.
        #if DEBUG
        hub.player.installSnapshotState(queue: Array(data.tracks.prefix(14)), startAt: 2, playing: true, position: 83, duration: 215)
        #endif
        UserDefaults.standard.removeObject(forKey: MusicShellKeys.destination)
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Unwraps or throws; the fixture is plain code, not a test body.
private func requiredValue<T>(_ value: T?) throws -> T {
    guard let value else { throw MusicError.unsupported("fixture defaults suite") }
    return value
}


/// A lyrics source for the lyrics scenarios: it answers with a short synced text, or with nothing.
struct MusicSnapshotLyricsSource: MusicLyricsProvider {
    static let id = MusicLyricsSources.lrclib
    var info = MusicProviderInfo(id: MusicSnapshotLyricsSource.id, name: "Sample lyrics", summary: "Fixture data for layout checks.")
    var capabilities: MusicCapabilities { .lyrics }
    let found: Bool
    init(found: Bool) { self.found = found }
    func lyrics(for track: MusicTrack) async throws -> MusicLyrics? {
        guard found else { return nil }
        let words = ["A long road ends where the lights begin", "Hold the evening a little longer", "Every window says your name", "Sing it back to me", "Under a sky the colour of tea"]
        return MusicLyrics(synced: words.enumerated().map { MusicLyricLine(timeMs: Int64(1_000 + $0.offset * 12_000), text: $0.element) }, providerID: Self.id)
    }
}

extension MusicSnapshotCatalogue: MusicRegionalDiscovery {
    func featured(region: String) async throws -> [MusicBrowseSection] { try await featured() }
}
