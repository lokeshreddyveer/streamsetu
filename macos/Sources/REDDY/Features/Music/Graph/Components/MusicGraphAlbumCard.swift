import SwiftUI

// MusicGraphAlbumCard: an album or soundtrack card with an optional film caption, a one-line reason and a small tag. Opens the album page.
//
// API (owned by the album/soundtrack page package; reuse it):
//   MusicGraphAlbumCard(title: String, subtitle: String? = nil, imageRef: String? = nil, reason: String? = nil, tag: MusicGraphTag? = nil,
//                       width: CGFloat = MusicCardGeometry.defaultWidth, action: @escaping () -> Void)
// `subtitle` is the line under the title (the film caption "From Awaara (1951)", or the year). Built on `MusicCard`, so the cover, hover, focus ring
// and geometry are exactly the shelf's own; the reason sits under it in a fixed two-line box.

struct MusicGraphAlbumCard: View {
    let title: String
    var subtitle: String?
    var imageRef: String?
    var reason: String?
    var tag: MusicGraphTag?
    var width: CGFloat
    /// The graph id of the album, soundtrack or playlist, so its cover can be found through the graph, the film it belongs to, or a catalogue.
    var entity: MusicEntityID?
    let action: () -> Void

    init(title: String, subtitle: String? = nil, imageRef: String? = nil, reason: String? = nil, tag: MusicGraphTag? = nil,
         width: CGFloat = MusicCardGeometry.defaultWidth, entity: MusicEntityID? = nil, action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.imageRef = imageRef; self.reason = reason; self.tag = tag; self.width = width; self.entity = entity; self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            MusicCard(title: title, subtitle: subtitle, thumbs: MusicGraphThumbs.thumbs(imageRef), width: width,
                      subject: .card(.album, name: title, entity: entity), action: action)
            // The reason box is always the same height (two lines), so the cards of one shelf end at the same line whether or not each has a reason.
            if let reason { MusicGraphReasonLabel(reason, tag: tag, lines: 2).frame(width: width, alignment: .leading) }
            else { Color.clear.frame(width: width, height: MusicGraphReasonLabel.height(lines: 2)).accessibilityHidden(true) }
        }
    }
}
