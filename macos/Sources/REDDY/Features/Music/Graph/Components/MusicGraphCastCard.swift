import SwiftUI

// MusicGraphCastCard: one verified cast member of a film: photo, actor name, character, role and a "View profile" affordance. Opens the person page
// on the actor role.
//
// API (owned by the album/soundtrack page package; the film and person pages reuse it):
//   MusicGraphCastCard(name: String, character: String? = nil, roleCaption: String = "Actor", imageRef: String? = nil, detail: String? = nil,
//                      tag: MusicGraphTag? = nil, width: CGFloat = MusicCardGeometry.defaultWidth, action: @escaping () -> Void)
// `detail` tells two people of one name apart ("b. 1924"). The whole card is one button; "View profile" is its visible label, not a second control.

struct MusicGraphCastCard: View {
    let name: String
    var character: String?
    var roleCaption: String
    var imageRef: String?
    var detail: String?
    var tag: MusicGraphTag?
    var width: CGFloat
    /// The graph id of the person, so the photo can be found through what the graph knows about them.
    var entity: MusicEntityID?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(name: String, character: String? = nil, roleCaption: String = Localized.string("Actor"), imageRef: String? = nil, detail: String? = nil,
         tag: MusicGraphTag? = nil, width: CGFloat = MusicCardGeometry.defaultWidth, entity: MusicEntityID? = nil, action: @escaping () -> Void) {
        self.name = name; self.character = character; self.roleCaption = roleCaption; self.imageRef = imageRef; self.detail = detail
        self.tag = tag; self.width = width; self.entity = entity; self.action = action
    }

    private var characterLine: String? { character.flatMap { $0.isEmpty ? nil : Localized.string("as %@", $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: MusicCardGeometry.coverToText) {
                    MusicGraphCover(imageRef: imageRef, aspect: MusicGraphCardMetrics.castAspect, seed: name, initials: MusicArtistPortrait.initials(name),
                                    subject: .card(.person, name: name, entity: entity), hovering: hovering, focused: focused)
                    VStack(alignment: .leading, spacing: MusicCardGeometry.textSpacing) {
                        Text(verbatim: name).musicText(.card).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(ColorTokens.textPrimary)
                        if let detail, !detail.isEmpty { Text(verbatim: detail).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textTertiary) }
                        Text(verbatim: characterLine ?? " ").musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary)
                        Text(verbatim: roleCaption).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textTertiary)
                        Label { Text("View profile").musicText(.caption) } icon: { Image(systemName: "chevron.right").font(.system(size: MusicIconSize.tiny)) }
                            .labelStyle(.titleAndIcon).foregroundStyle(hovering || focused ? ColorTokens.textPrimary : ColorTokens.textSecondary)
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
            .accessibilityLabel([name, detail, characterLine, roleCaption].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint(Localized.string("View profile"))
            .atlas("control.music.graphCastCard")
            if let tag { MusicGraphTagView(tag) }
        }
    }
}
