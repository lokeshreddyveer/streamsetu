import Testing
import Foundation
@testable import REDDY

@Suite("Album songs are saved per store") struct AlbumStorefrontKeyTests {
    private static func source(_ rel: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }     // Music, REDDYTests, Tests -> macos is one more
        dir.deleteLastPathComponent()
        return try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/" + rel), encoding: .utf8)
    }

    @Test func theAlbumKeysCarryTheStore() throws {
        let src = try Self.source("Services/Music/Core/MusicPageCache.swift")
        #expect(src.contains(#""albumTracks", id, Self.storefront"#) && src.contains(#""album", id, Self.storefront"#), "a list saved under one country must not be served under another")
    }

    @Test func aRefreshAsksTheSourceAndAFailedListWithGraphRowsOffersARetry() throws {
        let m = try Self.source("Features/Music/Graph/Album/MusicSoundtrackPageModel.swift")
        #expect(m.contains("askedForFreshSongs || provider.id == LocalFilesProvider.providerID") && m.contains("forgetAlbum(providerID: provider.id, id: ref.id)"),
                "Refresh metadata and a local folder skip the six-hour saved copy")
        let c = try Self.source("Services/Music/Core/MusicPageCache.swift")
        #expect(c.contains(#"MusicFetch.key(providerID, "albumTracks", id, Self.storefront)"#), "the forgotten key is the saved key")
        #expect(m.contains("songsPartial || songsState == .failed"))
        for f in ["MusicSoundtrackSongsSection", "MusicAlbumTracksSection"] {
            #expect(try Self.source("Features/Music/Graph/Album/\(f).swift").contains("if page.songsNeedRetry {"), "\(f) offers the retry while graph rows are shown")
        }
    }

    @Test func keysForDifferentStoresDiffer() {
        #expect(MusicFetch.key("itunes", "albumTracks", "6787217382", "us") != MusicFetch.key("itunes", "albumTracks", "6787217382", "jp"))
    }

    @Test func anAnsweredButEmptyAlbumIsNotAFailure() throws {
        let m = try Self.source("Features/Music/Graph/Album/MusicSoundtrackPageModel.swift")
        #expect(m.contains("loaded.isEmpty ? .empty : .loaded"))
        let v = try Self.source("Features/Music/Graph/Album/MusicSoundtrackSongsSection.swift")
        #expect(v.contains("songsState == .empty"), "an empty answer gets its own message and a retry")
    }
}

@Suite("Album header names the artist") struct AlbumHeaderArtistTests {
    @Test func theHeaderHasAnArtistLineForAlbumsWithoutMakers() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/Graph/Album/MusicSoundtrackHeaderSection.swift"), encoding: .utf8)
        #expect(src.contains("artistsLine(h)") && src.contains("h.makers.isEmpty || h.film == nil, let album = page.providerAlbum"), "an album that is not a film soundtrack names its artist, linked, even with a composer credit")
        #expect(src.contains("hub.open(.artist(hub.artist(from: a, providerID: album.providerID)))"))
    }
}

@Suite("Song page builds its playable row quickly") struct SongPageBuildTrackTests {
    @Test func thePerformersAreReadSideBySide() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/Graph/MusicSongPageModel.swift"), encoding: .utf8)
        let build = try #require(src.components(separatedBy: "func buildTrack()").dropFirst().first)
        #expect(build.contains("withTaskGroup"), "one read after another delayed the Play button by the sum of all reads")
    }
}

@Suite("Album rows are keyboard navigable") struct AlbumRowKeyboardTests {
    @Test func theRowsMoveWithArrowsHomeEndAndReturn() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/Graph/Album/MusicSoundtrackSongsSection.swift"), encoding: .utf8)
        for key in [".downArrow", ".upArrow", ".home", ".end", ".return"] { #expect(src.contains("onKeyPress(\(key))"), "\(key) must be handled on a song row") }
        #expect(src.contains("focused(focus, equals: row.id)"))
    }
}

@Suite("Page header stacks on a narrow page") struct PageHeaderCompactTests {
    @Test func theCoverMovesAboveTheTextAtCompactWidth() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/MusicDetailPages.swift"), encoding: .utf8)
        #expect(src.contains("layoutClass == .compact ? AnyLayout(VStackLayout"), "song, playlist and user headers need a stacked layout at compact width")
        #expect(src.contains("MusicGraphFlowLayout(spacing: 10) { actions() }"), "the action row wraps instead of overflowing")
    }
}

@Suite("Graph album cards end at one line") struct GraphAlbumCardHeightTests {
    @Test func theReasonBoxIsReservedWhetherOrNotThereIsAReason() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/Graph/Components/MusicGraphAlbumCard.swift"), encoding: .utf8)
        #expect(src.contains("else { Color.clear.frame(width: width, height: MusicGraphReasonLabel.height(lines: 2))"))
    }
}

@Suite("Album songs read every page") struct AlbumPagingTests {
    @Test func thePageLoopEndsOnTheSourcesAnswerNotAFixedCount() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = try String(contentsOf: dir.appendingPathComponent("Sources/REDDY/Features/Music/Graph/Album/MusicSoundtrackPageModel.swift"), encoding: .utf8)
        #expect(!src.contains("for n in 0..<12"), "no 12-page cap")
        #expect(src.contains("seenCursors.insert(next).inserted") && src.contains("!fresh.isEmpty"), "a repeated cursor or a page with nothing new ends the loop")
        #expect(src.contains("pageCeiling = 100") && src.contains("songsPartial = true }; break"), "hitting the last-resort ceiling marks the list incomplete")
    }
}
