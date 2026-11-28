import Foundation
import CoreGraphics
import ImageIO
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias MusicPlatformImage = NSImage
#else
import UIKit
typealias MusicPlatformImage = UIImage
#endif

// Music covers never touch the app-wide artwork code. Everything is decoded with ImageIO into a CGImage, which both platforms draw directly; the
// platform image type is only built at the edges that need it (Now Playing).

/// A decoded, already downsampled cover. CGImage is immutable, so sharing it between threads is safe.
struct MusicDecodedImage: @unchecked Sendable {
    let cg: CGImage
    var pixelWidth: Int { cg.width }
    var pixelHeight: Int { cg.height }
    /// Bytes the bitmap occupies, used as the memory cache cost.
    var cost: Int { max(1, cg.bytesPerRow * cg.height) }

    func platformImage() -> MusicPlatformImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        UIImage(cgImage: cg)
        #endif
    }
}

enum MusicArtworkCodec {
    /// Decodes at most `maxPixel` on the long side. Never decodes the full-size bitmap and never scales a small picture up.
    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0, let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var limit = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
            limit = min(maxPixel, max(w, h))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// JPEG for opaque covers, PNG when there is transparency.
    static func encode(_ image: CGImage) -> Data? {
        let opaque: Bool = {
            switch image.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return true; default: return false }
        }()
        let out = NSMutableData()
        let type = opaque ? "public.jpeg" : "public.png"
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Decoding runs off the calling actor so a scroll full of covers never queues behind one decode.
    static func decode(_ data: Data, maxPixel: Int) async -> MusicDecodedImage? {
        await MusicDecodeGate.shared.acquire()
        let result = await Task.detached(priority: .utility) { downsample(data, maxPixel: maxPixel).map(MusicDecodedImage.init) }.value
        await MusicDecodeGate.shared.release()
        return result
    }
}
