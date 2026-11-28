import Testing
import Foundation
import CoreGraphics
import ImageIO
#if canImport(REDDY)
@testable import REDDY
#else
@testable import ArtworkCore
#endif

@Suite("Artwork slots, sizing, retry, placeholders")
struct MusicArtworkSizingTests {
    @Test func theSlotTableMatchesTheOrderedSizes() {
        #expect(MusicArtworkSlot.avatar.pixels() == 64)
        #expect(MusicArtworkSlot.row.pixels() == 120)
        #expect(MusicArtworkSlot.backdrop.pixels() == 96)
        #expect(MusicArtworkSlot.card.ladder(scale: 1) == [200] && MusicArtworkSlot.card.ladder(scale: 2) == [400])
        #expect(MusicArtworkSlot.miniPlayer.pixels() == 480)
        #expect(MusicArtworkSlot.nowPlaying.ladder() == [720, 400, 120])
        #expect(MusicArtworkSlot.mediaSession.pixels() == 512)
        #expect(MusicArtworkSlot.forPoints(24) == .avatar && MusicArtworkSlot.forPoints(44) == .row && MusicArtworkSlot.forPoints(150) == .card)
        #expect(MusicArtworkSlot.row.decodeCap() == 240)
    }

    @Test func sizeHintsAreRewrittenPerHost() {
        #expect(MusicArtworkURLSizing.rewrite("https://lh3.googleusercontent.com/abc=w544-h544-l90-rj", to: 120) == "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj")
        #expect(MusicArtworkURLSizing.rewrite("https://lh3.googleusercontent.com/abc=s400", to: 120) == "https://lh3.googleusercontent.com/abc=w120-h120")
        #expect(MusicArtworkURLSizing.rewrite("https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/100x100bb.jpg", to: 400) == "https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/400x400bb.jpg")
        #expect(MusicArtworkURLSizing.rewrite("https://cdn-images.dzcdn.net/images/cover/h/500x500-000000-80-0-0.jpg", to: 120) == "https://cdn-images.dzcdn.net/images/cover/h/250x250-000000-80-0-0.jpg")
        #expect(MusicArtworkURLSizing.rewrite("https://c.saavncdn.com/968/A-Tamil-2020-50x50.jpg", to: 400) == "https://c.saavncdn.com/968/A-Tamil-2020-500x500.jpg")
        #expect(MusicArtworkURLSizing.rewrite("https://coverartarchive.org/release-group/x/front-500", to: 120) == "https://coverartarchive.org/release-group/x/front-250")
        #expect(MusicArtworkURLSizing.rewrite("https://image.tmdb.org/t/p/w500/p.jpg", to: 120) == "https://image.tmdb.org/t/p/w154/p.jpg")
        // Wikimedia accepts only its standard widths: 400 becomes 500, never 400.
        #expect(MusicArtworkURLSizing.rewrite("https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3c/A.jpg/330px-A.jpg", to: 400) == "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3c/A.jpg/500px-A.jpg")
        #expect(MusicArtworkURLSizing.rewrite("https://commons.wikimedia.org/wiki/Special:FilePath/A.jpg?width=400", to: 400) == "https://commons.wikimedia.org/wiki/Special:FilePath/A.jpg?width=500")
    }

    @Test func nothingToChangeGivesNil() {
        #expect(MusicArtworkURLSizing.rewrite("https://example.com/cover.jpg", to: 400) == nil)
        #expect(MusicArtworkURLSizing.rewrite("https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/400x400bb.jpg", to: 400) == nil)
        #expect(MusicArtworkURLSizing.rewrite("not a url", to: 400) == nil)
    }

    @Test func videoThumbnailsAskForTheBigFileOnlyInABigSlot() {
        let base = "https://i.ytimg.com/vi/abc/hqdefault.jpg"
        #expect(MusicArtworkURLSizing.rewrite(base, to: 120) == "https://i.ytimg.com/vi/abc/mqdefault.jpg")
        #expect(MusicArtworkURLSizing.rewrite(base, to: 400) == nil)
        #expect(MusicArtworkURLSizing.rewrite(base, to: 720) == "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
        #expect(MusicArtworkURLSizing.rewrite("https://i.ytimg.com/vi/abc/default.jpg", to: 720) == nil)
    }

    @Test func retryIsSizedThenOriginalOnceAndNeverTwiceTheSameAddress() {
        #expect(MusicArtworkURLSizing.attempts(for: "https://lh3.googleusercontent.com/a=s400", pixels: 120) == ["https://lh3.googleusercontent.com/a=w120-h120", "https://lh3.googleusercontent.com/a=s400"])
        #expect(MusicArtworkURLSizing.attempts(for: "https://example.com/c.jpg", pixels: 120) == ["https://example.com/c.jpg"])
        let same = "https://is1-ssl.mzstatic.com/image/thumb/x/y.jpg/400x400bb.jpg"
        #expect(MusicArtworkURLSizing.attempts(for: same, pixels: 400) == [same])
    }

    @Test func theGreyVideoPlaceholderIsAMissExceptTheRealDefaultFile() {
        #expect(MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/maxresdefault.jpg", width: 120, height: 90))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/default.jpg", width: 120, height: 90))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/maxresdefault.jpg", width: 1280, height: 720))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://example.com/a.jpg", width: 120, height: 90))
    }

    @Test func theGreyPlaceholderIsFoundInTheDownloadedBytes() throws {
        func png(_ w: Int, _ h: Int) throws -> Data {
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let out = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil); CGImageDestinationFinalize(dest)
            return out as Data
        }
        let grey = try png(120, 90), real = try png(480, 360)
        #expect(MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/maxresdefault.jpg", data: grey))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/maxresdefault.jpg", data: real))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://example.com/a.png", data: grey))
        #expect(!MusicArtworkPlaceholder.isMissing(address: "https://i.ytimg.com/vi/abc/default.jpg", data: grey))
    }

    @Test func nowPlayingTriesSevenTwentyThenFourHundredThenOneTwentyThenTheOriginal() {
        let u = "https://lh3.googleusercontent.com/a=w544-h544-l90-rj"
        #expect(MusicArtworkURLSizing.attempts(for: u, ladder: MusicArtworkSlot.nowPlaying.ladder()) == [
            "https://lh3.googleusercontent.com/a=w720-h720-l90-rj", "https://lh3.googleusercontent.com/a=w400-h400-l90-rj", "https://lh3.googleusercontent.com/a=w120-h120-l90-rj", u])
        #expect(MusicArtworkURLSizing.attempts(for: "https://example.com/c.jpg", ladder: [720, 400, 120]) == ["https://example.com/c.jpg"])
    }

    @Test func identityIgnoresSizeSoDistinctMeansDistinctCovers() {
        #expect(MusicArtworkURLSizing.identity("https://lh3.googleusercontent.com/a=w120-h120") == MusicArtworkURLSizing.identity("https://lh3.googleusercontent.com/a=w544-h544-l90-rj"))
        #expect(MusicArtworkURLSizing.identity("https://c.saavncdn.com/9/A-50x50.jpg") == MusicArtworkURLSizing.identity("https://c.saavncdn.com/9/A-500x500.jpg"))
        #expect(MusicArtworkURLSizing.identity("https://c.saavncdn.com/9/A-50x50.jpg") != MusicArtworkURLSizing.identity("https://c.saavncdn.com/9/B-50x50.jpg"))
        #expect(MusicArtworkURLSizing.isServiceCollage("https://lh3.googleusercontent.com/collage=s400"))
        #expect(!MusicArtworkURLSizing.isServiceCollage("https://lh3.googleusercontent.com/chosen=w400-h400-l90-rj"))
    }
}

@Suite("Playlist covers and tiles")
struct MusicPlaylistCoverTests {
    private func c(_ n: String, _ size: Int = 120) -> String { "https://c.saavncdn.com/x/\(n)-\(size == 120 ? "150x150" : "500x500").jpg" }

    @Test func fourDistinctCoversMakeAMosaic() {
        let plan = MusicPlaylistCoverPlan.make(memberCovers: [c("A"), c("B"), nil, c("C"), c("D"), c("E")])
        #expect(plan == .mosaic([c("A"), c("B"), c("C"), c("D")]))
    }

    @Test func sixSongsOfOneAlbumAreOneSleeveNotFour() {
        let plan = MusicPlaylistCoverPlan.make(memberCovers: [c("A"), c("A", 400), c("A"), c("A"), c("A"), c("A")])
        #expect(plan == .single(c("A")))
        #expect(MusicPlaylistCoverPlan.make(memberCovers: [c("A"), c("B"), c("B", 400), c("A")]) == .single(c("A")) || MusicPlaylistCoverPlan.make(memberCovers: [c("A"), c("B")]) != .none)
    }

    @Test func noCoversLeavesTheDesignedGradient() {
        #expect(MusicPlaylistCoverPlan.make(memberCovers: []) == .none)
        #expect(MusicPlaylistCoverPlan.make(memberCovers: [nil, "", nil]) == .none)
    }

    @Test func onlyTheFirstSixtySongsAreScanned() {
        let many: [String?] = Array(repeating: c("A"), count: 60) + [c("B"), c("C"), c("D")]
        #expect(MusicPlaylistCoverPlan.make(memberCovers: many) == .single(c("A")))
    }

    @Test func twoDistinctGivesTheFirstAlone() {
        #expect(MusicPlaylistCoverPlan.make(memberCovers: [c("A"), c("B")]) == .single(c("A")))
    }

    @Test func customCoverRules() {
        #expect(MusicPlaylistCover.validateCustom(byteCount: 1_000, typeIdentifier: "public.png") == .ok)
        #expect(MusicPlaylistCover.validateCustom(byteCount: 8 * 1024 * 1024, typeIdentifier: "public.jpeg") == .ok)
        #expect(MusicPlaylistCover.validateCustom(byteCount: 8 * 1024 * 1024 + 1, typeIdentifier: "public.jpeg") == .tooLarge)
        #expect(MusicPlaylistCover.validateCustom(byteCount: 10, typeIdentifier: "com.compuserve.gif") == .wrongType)
        #expect(MusicPlaylistCover.validateCustom(byteCount: 10, typeIdentifier: nil) == .wrongType)
    }

    @Test func aCollageIsNeverABackdrop() {
        let collage = "https://lh3.googleusercontent.com/col=s400"
        let member = c("A")
        #expect(MusicPlaylistCover.backdrop(own: [collage], memberCovers: [member], seed: "p1") == member)
        #expect(MusicPlaylistCover.backdrop(own: [collage], memberCovers: [], seed: "p1") == nil)
        #expect(MusicPlaylistCover.backdrop(own: ["https://lh3.googleusercontent.com/c=w400-h400"], memberCovers: [member], seed: "p1") == "https://lh3.googleusercontent.com/c=w400-h400")
        let pool = [c("A"), c("B"), c("C")].map { Optional($0) }
        #expect(MusicPlaylistCover.backdrop(own: [], memberCovers: pool, seed: "same") == MusicPlaylistCover.backdrop(own: [], memberCovers: pool, seed: "same"))
    }

    @Test func mosaicComposesFourSquaresFromWideAndTallPictures() throws {
        func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }
        let out = try #require(MusicPlaylistMosaic.compose([solid(200, 100, 255, 0, 0), solid(100, 200, 0, 255, 0), solid(50, 50, 0, 0, 255), solid(80, 80, 255, 255, 0)], side: 64))
        #expect(out.width == 64 && out.height == 64)
        // Read the four quadrant centres: top-left red, top-right green, bottom-left blue, bottom-right yellow.
        let data = try #require(out.dataProvider?.data as Data?)
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let i = y * out.bytesPerRow + x * 4; return (data[i], data[i + 1], data[i + 2]) }
        // The colour space conversion moves values a little, so compare with a tolerance.
        func near(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Bool { abs(Int(a.0) - Int(b.0)) < 60 && abs(Int(a.1) - Int(b.1)) < 60 && abs(Int(a.2) - Int(b.2)) < 60 }
        #expect(near(px(16, 16), (255, 0, 0))); #expect(near(px(48, 16), (0, 255, 0))); #expect(near(px(16, 48), (0, 0, 255))); #expect(near(px(48, 48), (255, 255, 0)))
        #expect(MusicPlaylistMosaic.compose([solid(8, 8, 0, 0, 0)], side: 64) == nil)
    }

    @Test func tileCoversAreFreshForSevenDaysThenStaleButStillShown() {
        #expect(MusicTileCoverPolicy.state(age: nil) == .absent)
        #expect(MusicTileCoverPolicy.state(age: 6 * 86_400) == .fresh)
        #expect(MusicTileCoverPolicy.state(age: 8 * 86_400) == .stale)
        #expect(MusicTileCoverPolicy.parallel == 6)
    }
}

// The dominant-colour and baked-wash recipe already in the app (Services/Music/Theme/MusicAdaptiveColor.swift), pinned to the owner's numbers.
@Suite("Dominant colour and wash follow the recipe")
struct MusicDominantColourRecipeTests {
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2, 255] } }

    @Test func sampleSizeAndThresholds() {
        #expect(MusicAdaptiveColor.sampleSide == 32)
        #expect(MusicAdaptiveColor.minSaturation == 0.15)
        #expect(MusicAdaptiveColor.darkTarget == 0.65 && MusicAdaptiveColor.lightTarget == 0.39)
        #expect(MusicCoverWash.side == 160 && MusicCoverWash.blurRadius == 28 && MusicCoverWash.cacheLimit == 8)
    }

    @Test func aGreyscaleCoverIsRejected() {
        let grey = image(Array<(UInt8, UInt8, UInt8)>(repeating: (128, 128, 128), count: 32 * 32))
        #expect(MusicAdaptiveColor.dominant(rgba: grey) == nil)
    }

    @Test func nearBlackAreaDoesNotBeatASaturatedMidBrightArea() throws {
        let px: [(UInt8, UInt8, UInt8)] = Array(repeating: (6, 6, 8), count: 800) + Array(repeating: (200, 40, 40), count: 224)
        let c = try #require(MusicAdaptiveColor.dominant(rgba: image(px)))
        #expect(c.r > 0.6 && c.g < 0.3)
    }

    @Test func accentIsPulledToThePerModeBrightness() {
        for base in [MusicRGB(0.9, 0.2, 0.2), MusicRGB(0.1, 0.1, 0.8), MusicRGB(0.3, 0.8, 0.3)] {
            #expect(abs(MusicAdaptiveColor.brightness(MusicAdaptiveColor.toAccent(base, dark: true)) - 0.65) < 0.03)
            #expect(abs(MusicAdaptiveColor.brightness(MusicAdaptiveColor.toAccent(base, dark: false)) - 0.39) < 0.03)
        }
    }

    @Test func washOpacityKeepsLyricsReadable() {
        #expect(MusicCoverWash.opacity(dark: true, darkest: 0, brightest: 1) <= 0.2 + 1e-9)
        #expect(MusicCoverWash.opacity(dark: false, darkest: 0, brightest: 1) <= 0.15 + 1e-9)
        #expect(MusicCoverWash.opacity(dark: true, darkest: 0, brightest: 0.1) == 1)
    }
}
