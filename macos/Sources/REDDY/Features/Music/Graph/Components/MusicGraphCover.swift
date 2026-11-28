import SwiftUI

// MusicGraphCover and MusicGraphCardWidth: the shared picture frame and the card widths of the connected-universe cards.
//
// API:
//   MusicGraphCardWidth.width(for: MusicLayoutClass) -> CGFloat        (compact 128, otherwise 150; read the class from `@Environment(\.musicLayoutClass)`)
//   MusicGraphCover(imageRef:, aspect:, corner:, seed:, initials:, hovering:, focused:)   (a picture of fixed shape; aspect is height / width)
//   MusicGraphCardMetrics.height(width:, aspect:, textLines:)           (the box a card occupies, for skeletons)

enum MusicGraphCardWidth {
    static func width(for cls: MusicLayoutClass) -> CGFloat { cls == .compact ? MusicCardSize.compact.width : MusicCardSize.standard.width }
}

enum MusicGraphCardMetrics {
    /// The portrait ratio of a film poster (height over width).
    static let posterAspect: CGFloat = 1.5
    /// The portrait ratio of a cast photo: the 2:3 of the photos the film sources give, so a face is not cropped to a squarer frame.
    static let castAspect: CGFloat = 1.5
    static func height(width: CGFloat, aspect: CGFloat, textLines: Int) -> CGFloat {
        width * aspect + MusicCardGeometry.coverToText + CGFloat(textLines) * MusicCardGeometry.titleLineHeight
    }
}

/// A picture of one fixed shape with the hover stroke, the keyboard focus ring and the designed fallback of every Music cover. No layout change on
/// hover; the focus ring is a stroke, not a colour change.
struct MusicGraphCover: View {
    let imageRef: String?
    var aspect: CGFloat = 1
    var corner: CGFloat = MusicCorner.card
    var seed: String = ""
    var initials: String?
    /// What the picture stands for: a missing poster or photo is looked up (verified, never guessed) and the tile wears the right glyph.
    var subject: MusicArtworkSubject?
    /// Where it is drawn, so the host is asked for the size that place needs (a poster, a portrait, a hero).
    var slot: MusicArtworkSlot?
    var hovering = false
    var focused = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        MusicCoverImage(thumbs: MusicGraphThumbs.thumbs(imageRef), artworkClass: .tile, corner: corner, seed: seed.isEmpty ? nil : seed, initials: initials, subject: subject, slot: slot)
            .aspectRatio(1 / aspect, contentMode: .fit)
            .scaleEffect(hovering && !reduceMotion ? MusicCardGeometry.hoverScale : 1)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .musicHoverLift(hovering, cornerRadius: corner)
            .overlay(shape.strokeBorder(accent, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
            .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
            .musicAnimation(.focus, reduce: reduceMotion, value: focused)
            .accessibilityHidden(true)
    }
}
