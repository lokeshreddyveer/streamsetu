import Foundation
import CoreGraphics

// Playlist covers. A playlist with no cover of its own shows a local 2x2 of up to four DISTINCT member covers (six songs from one album do not draw
// one sleeve four times); fewer than four distinct covers show the first alone; none leaves the designed gradient. A service collage is never a backdrop.
// A chosen cover is JPEG or PNG, at most 8 MB. Pure planning and CoreGraphics composing, shared with iOS.

enum MusicPlaylistCoverPlan: Hashable, Sendable {
    case mosaic([String])
    case single(String)
    case none

    /// How many songs are looked at, front to back.
    static let scanLimit = 60

    /// The plan for a playlist whose songs have these covers (nil for a song with none), in playlist order.
    static func make(memberCovers: [String?]) -> MusicPlaylistCoverPlan {
        var seen = Set<String>(), picked: [String] = []
        for case let c? in memberCovers.prefix(scanLimit) where !c.isEmpty {
            if seen.insert(MusicArtworkURLSizing.identity(c)).inserted { picked.append(c) }
            if picked.count == 4 { break }
        }
        switch picked.count {
        case 4: return .mosaic(picked)
        case 0: return .none
        default: return .single(picked[0])
        }
    }

    /// A key for caching the composed picture: the identities of what it was made from.
    var key: String {
        switch self {
        case .mosaic(let l): "m:" + l.map(MusicArtworkURLSizing.identity).joined(separator: "|")
        case .single(let s): "s:" + MusicArtworkURLSizing.identity(s)
        case .none: "n"
        }
    }

    var addresses: [String] {
        switch self { case .mosaic(let l): l; case .single(let s): [s]; case .none: [] }
    }
}

enum MusicPlaylistCover {
    /// A chosen cover: the service's uploader takes JPEG and PNG only, and the app keeps it to 8 MB.
    static let customMaxBytes = 8 * 1024 * 1024
    static let customTypes: Set<String> = ["public.jpeg", "public.png"]

    enum Verdict: Equatable, Sendable { case ok, tooLarge, wrongType }

    static func validateCustom(byteCount: Int, typeIdentifier: String?) -> Verdict {
        guard let t = typeIdentifier, customTypes.contains(t) else { return .wrongType }
        return byteCount > customMaxBytes ? .tooLarge : .ok
    }

    /// A header backdrop for a playlist with no cover of its own: the playlist's own picture unless it is the service's collage, else a member cover chosen
    /// once per load (stable for one `seed`, so the page does not change colour while it is open).
    static func backdrop(own: [String], memberCovers: [String?], seed: String) -> String? {
        if let ok = own.last(where: { !MusicArtworkURLSizing.isServiceCollage($0) }) { return ok }
        let members = memberCovers.compactMap { $0 }.filter { !$0.isEmpty && !MusicArtworkURLSizing.isServiceCollage($0) }
        guard !members.isEmpty else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return members[Int(h % UInt64(members.count))]
    }
}

/// Draws the 2x2. Each picture is centre-cropped to a square, so nothing is stretched.
enum MusicPlaylistMosaic {
    static func compose(_ images: [CGImage], side: Int = 320) -> CGImage? {
        guard images.count == 4, side >= 8, side % 2 == 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let half = side / 2
        // CoreGraphics' origin is bottom-left: the first picture goes top-left, so its row is the upper one.
        let cells = [(0, half), (half, half), (0, 0), (half, 0)]
        for (image, cell) in zip(images, cells) {
            let crop = squareCrop(image)
            ctx.draw(crop, in: CGRect(x: cell.0, y: cell.1, width: half, height: half))
        }
        return ctx.makeImage()
    }

    /// The largest centred square of an image.
    static func squareCrop(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w != h else { return image }
        let s = min(w, h)
        return image.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)) ?? image
    }
}
