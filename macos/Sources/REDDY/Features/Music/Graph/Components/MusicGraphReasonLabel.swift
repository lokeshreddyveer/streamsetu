import SwiftUI

// MusicGraphReasonLabel and MusicGraphTag: the one-line "why is this here" under a card, and the small status tags of the connected-universe pages.
//
// API (owned by the album/soundtrack page package, reused by the song, person and film pages):
//   MusicGraphReasonLabel(_ text: String, tag: MusicGraphTag? = nil, lines: Int = 1)
//   MusicGraphTag: .inferredFilmLink, .filmCredit, .possiblyRelated, .source(String), .custom(String)
//     MusicGraphTag(status: EdgeStatus, level: CreditLevel) -> MusicGraphTag?   (film-level credit -> .filmCredit; non-verified -> .inferredFilmLink only
//     when `forFilmLink` is true)
//   MusicGraphThumbs.thumbs(_ ref: String?) -> [MusicThumbnail]    (an entity's `imageRef` as cover input)

/// A small status tag. It is text plus a shape (never colour alone) and carries its own accessibility words.
enum MusicGraphTag: Hashable, Sendable {
    case inferredFilmLink
    case filmCredit
    case possiblyRelated
    /// "Source: Wikipedia", for a section whose licence asks for attribution.
    case source(String)
    case custom(String)

    /// The tag a credit or link claim earns: a film-level credit is a "film credit"; with `forFilmLink` a claim that is not verified is an "inferred film link".
    init?(status: EdgeStatus, level: CreditLevel = .unknown, forFilmLink: Bool = false) {
        if level == .film && !forFilmLink { self = .filmCredit }
        else if forFilmLink && status != .verified { self = .inferredFilmLink }
        else { return nil }
    }

    var title: String {
        switch self {
        case .inferredFilmLink: Localized.string("Inferred film link")
        case .filmCredit: Localized.string("Film credit")
        case .possiblyRelated: Localized.string("Possibly related")
        case .source(let s): Localized.string("Source: %@", s)
        case .custom(let s): s
        }
    }

    /// Tags that only hedge ("Inferred film link", "Possibly related") are never drawn: the owner wants no such labels anywhere.
    var isHedge: Bool { switch self { case .inferredFilmLink, .possiblyRelated: true; default: false } }

    var symbol: String {
        switch self {
        case .inferredFilmLink: "link.badge.plus"
        case .filmCredit: "film"
        case .possiblyRelated: "questionmark.circle"
        case .source: "info.circle"
        case .custom: "tag"
        }
    }

    /// What VoiceOver says (the same words, spelled out).
    var spoken: String {
        switch self {
        case .inferredFilmLink: Localized.string("The link to this film is inferred, not confirmed")
        case .filmCredit: Localized.string("Credited on the film, not on the song")
        case .possiblyRelated: Localized.string("Possibly related")
        case .source(let s): Localized.string("Source: %@", s)
        case .custom(let s): s
        }
    }
}

/// A small tag: glyph and words, so it never relies on colour. It does nothing when pressed, and looks like it.
struct MusicGraphTagView: View {
    let tag: MusicGraphTag
    init(_ tag: MusicGraphTag) { self.tag = tag }

    var body: some View {
        if tag.isHedge { EmptyView() } else { chip }
    }

    private var chip: some View {
        Label { Text(verbatim: tag.title).musicText(.micro) } icon: { Image(systemName: tag.symbol).font(.system(size: MusicIconSize.tiny)) }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(ColorTokens.textSecondary)
            .padding(.horizontal, MusicSpace.xs).padding(.vertical, MusicSpace.xxs / 2)
            // A tag is a LABEL, not a control: a soft fill and no edge, so it cannot be taken for a chip (chips have an edge, a hover and a click).
            .background(ColorTokens.elevated.opacity(0.7), in: Capsule())
            .musicContrastBorder(cornerRadius: MusicCardGeometry.roundCorner)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tag.spoken)
            .help(tag.spoken)
    }
}

/// One line saying why a card is on the page ("Same music director: Shankar-Jaikishan"), with an optional small tag. Fixed line box so cards do not
/// change height when the reason arrives.
struct MusicGraphReasonLabel: View {
    let text: String
    var tag: MusicGraphTag?
    var lines: Int

    init(_ text: String, tag: MusicGraphTag? = nil, lines: Int = 1) { self.text = text; self.tag = tag; self.lines = max(1, lines) }

    /// The height of the text block, so a shelf can reserve it.
    static func height(lines: Int = 1) -> CGFloat { (MusicTypeRole.caption.pointSize * MusicCardGeometry.leading).rounded(.up) * CGFloat(max(1, lines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Text(verbatim: text).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                .lineLimit(lines).multilineTextAlignment(.leading)
                .frame(minHeight: Self.height(lines: lines), alignment: .topLeading)
                .help(text)
            if let tag { MusicGraphTagView(tag) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An entity's `imageRef` (a picture address) as the thumbnails the cover views take.
enum MusicGraphThumbs {
    static func thumbs(_ ref: String?) -> [MusicThumbnail] {
        guard let ref, !ref.isEmpty else { return [] }
        return [MusicThumbnail(url: ref)]
    }
}
