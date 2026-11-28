import SwiftUI

// MusicGraphFilmCard: a film as a poster card. Opens the film page.
//
// API (owned by the album/soundtrack page package; reuse it, do not copy it):
//   MusicGraphFilmCard(title: String, year: Int? = nil, subtitle: String? = nil, imageRef: String? = nil, reason: String? = nil,
//                      tag: MusicGraphTag? = nil, width: CGFloat = MusicCardGeometry.defaultWidth, action: @escaping () -> Void)
// `subtitle` is the second line ("with Raj Kapoor"); `reason` is the one-line why under the card; `year` is appended to the title in speech and shown after it.
// The poster is 2:3. The whole card is one button; there is no nested control.

struct MusicGraphFilmCard: View {
    let title: String
    var year: Int?
    var subtitle: String?
    var imageRef: String?
    var reason: String?
    var tag: MusicGraphTag?
    var width: CGFloat = MusicCardGeometry.defaultWidth
    /// The graph id of the film, so a poster can be found (a free one, TMDB, IMDb) and, failing that, its soundtrack cover is shown.
    var entity: MusicEntityID?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(title: String, year: Int? = nil, subtitle: String? = nil, imageRef: String? = nil, reason: String? = nil, tag: MusicGraphTag? = nil,
         width: CGFloat = MusicCardGeometry.defaultWidth, entity: MusicEntityID? = nil, action: @escaping () -> Void) {
        self.title = title; self.year = year; self.subtitle = subtitle; self.imageRef = imageRef; self.reason = reason; self.tag = tag
        self.width = width; self.entity = entity; self.action = action
    }

    private var heading: String { year.map { "\(title) (\($0))" } ?? title }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: MusicCardGeometry.coverToText) {
                    MusicGraphCover(imageRef: imageRef, aspect: MusicGraphCardMetrics.posterAspect, seed: heading,
                                    subject: .card(.film, name: title, entity: entity, year: year), slot: .poster, hovering: hovering, focused: focused)
                    VStack(alignment: .leading, spacing: MusicCardGeometry.textSpacing) {
                        Text(verbatim: heading).musicText(.card).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(ColorTokens.textPrimary)
                        if let subtitle, !subtitle.isEmpty {
                            Text(verbatim: subtitle).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary)
                        }
                    }
                    .frame(minHeight: MusicCardGeometry.textBlockHeight, alignment: .top)
                }
                .frame(width: width, alignment: .leading)
                .frame(minHeight: MusicTokens.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onHover { hovering = $0 }
            .accessibilityLabel([Localized.string("Film"), heading, subtitle, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint(Localized.string("Opens the film page"))
            .atlas("control.music.graphFilmCard")
            if let reason { MusicGraphReasonLabel(reason, tag: tag, lines: 2).frame(width: width, alignment: .leading) }
            else if let tag { MusicGraphTagView(tag) }
        }
    }
}
