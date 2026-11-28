import SwiftUI

// MusicGraphPersonCard: a person or group as a round card with a role caption (a composer, a singer). Opens the person page on `role`.
//
// API (owned by the album/soundtrack page package; reuse it):
//   MusicGraphPersonCard(name: String, caption: String? = nil, imageRef: String? = nil, reason: String? = nil, tag: MusicGraphTag? = nil,
//                        width: CGFloat = MusicCardGeometry.defaultWidth, action: @escaping () -> Void)
// Built on `MusicCard` (round variant), so the geometry, hover and focus behaviour are the shelf's own. The initials stand in for a missing portrait.

struct MusicGraphPersonCard: View {
    let name: String
    var caption: String?
    var imageRef: String?
    var reason: String?
    var tag: MusicGraphTag?
    var width: CGFloat
    /// The graph id of the person or group, so the photo can be found through what the graph knows about them.
    var entity: MusicEntityID?
    let action: () -> Void

    init(name: String, caption: String? = nil, imageRef: String? = nil, reason: String? = nil, tag: MusicGraphTag? = nil,
         width: CGFloat = MusicCardGeometry.defaultWidth, entity: MusicEntityID? = nil, action: @escaping () -> Void) {
        self.name = name; self.caption = caption; self.imageRef = imageRef; self.reason = reason; self.tag = tag; self.width = width; self.entity = entity; self.action = action
    }

    var body: some View {
        VStack(alignment: .center, spacing: MusicSpace.xxs) {
            MusicCard(title: name, subtitle: caption, thumbs: MusicArtistPortrait.portraits(MusicGraphThumbs.thumbs(imageRef)), round: true, width: width,
                      subject: .card(.person, name: name, entity: entity), action: action)
            if let reason { MusicGraphReasonLabel(reason, tag: tag, lines: 2).multilineTextAlignment(.center) }
            else if let tag { MusicGraphTagView(tag) }
        }
        .frame(width: width)
    }
}
