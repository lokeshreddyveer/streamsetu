import SwiftUI
import CoreGraphics

/// The cover of a playlist that has none of its own: a local 2x2 of up to four DISTINCT member covers, the first cover alone when fewer than four differ,
/// or the designed tile when there are none. Composed on this device from covers the Music artwork service already holds; the service's own collage is
/// never used. The tile is under the picture from the first frame, so nothing flashes empty.
struct MusicPlaylistCoverArt: View {
    /// The thumbnails of the playlist's songs, in order (the first 60 are looked at).
    let members: [[MusicThumbnail]]
    /// The playlist's name, which seeds the designed tile.
    let name: String
    var size: CGFloat?
    var corner: CGFloat = MusicCorner.card
    @State private var composed: CGImage?
    @State private var composedFor: String?
    @Environment(\.displayScale) private var scale

    private var plan: MusicPlaylistCoverPlan {
        MusicPlaylistCoverPlan.make(memberCovers: members.prefix(MusicPlaylistCoverPlan.scanLimit).map { MusicArtworkService.pickThumbnail($0, neededPixels: 256) })
    }
    /// 320 px a side up to a 160 pt cover, 640 above (even numbers, so the quadrants are whole pixels).
    private var side: Int { (size ?? 190) * max(scale, 1) > 320 ? 640 : 320 }
    private var key: String { plan.key + "@\(side)" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            switch plan {
            case .single(let address):
                MusicCoverImage(thumbs: [MusicThumbnail(url: address)], artworkClass: .playlistCover, size: size, corner: corner, seed: name,
                                subject: MusicArtworkSubject(kind: .playlist, name: name))
            case .none:
                MusicCoverFallback(seed: name, kind: .playlist).frame(width: size, height: size)
            case .mosaic:
                MusicCoverFallback(seed: name, kind: .playlist)
                    .overlay { if let image = composedFor == key ? composed : MusicPlaylistMosaicMemory.shared.image(for: key) { Image(decorative: image, scale: 1).resizable().scaledToFill() } }
                    .frame(width: size, height: size)
                    .task(id: key) { await compose() }
            }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private func compose() async {
        guard case .mosaic(let addresses) = plan, MusicPlaylistMosaicMemory.shared.image(for: key) == nil else { return }
        var images: [CGImage] = []
        for a in addresses {
            guard let img = await MusicArtworkService.shared.load(a, targetPixelSize: side / 2) else { return }
            if Task.isCancelled { return }
            images.append(img.cg)
        }
        guard let out = MusicPlaylistMosaic.compose(images, side: side) else { return }
        MusicPlaylistMosaicMemory.shared.store(out, for: key)
        composed = out; composedFor = key
    }
}

/// The last few composed mosaics, so a playlist seen again paints its cover on the first frame. Memory only: they are rebuilt from the cover cache.
@MainActor
final class MusicPlaylistMosaicMemory {
    static let shared = MusicPlaylistMosaicMemory()
    static let limit = 16
    private var images: [String: CGImage] = [:]
    private var order: [String] = []

    func image(for key: String) -> CGImage? { images[key] }

    func store(_ image: CGImage, for key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > Self.limit { images[order.removeFirst()] = nil }
    }

    func clear() { images = [:]; order = [] }
}

extension MusicPlaylistCover {
    /// The thumbnails for a playlist page's blurred backdrop: its own picture unless it is the service's collage, else one member cover (stable per playlist).
    static func backdropThumbs(own: [MusicThumbnail], members: [[MusicThumbnail]], seed: String) -> [MusicThumbnail] {
        let ownAddresses = own.map(\.url)
        let memberAddresses = members.prefix(MusicPlaylistCoverPlan.scanLimit).map { MusicArtworkService.pickThumbnail($0, neededPixels: 256) }
        guard let a = backdrop(own: ownAddresses, memberCovers: memberAddresses, seed: seed) else { return [] }
        return own.filter { $0.url == a } + (own.contains { $0.url == a } ? [] : [MusicThumbnail(url: a)])
    }
}
