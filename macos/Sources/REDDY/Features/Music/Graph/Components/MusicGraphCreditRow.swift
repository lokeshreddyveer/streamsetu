import SwiftUI

// MusicGraphCreditRow: one role of a credits list ("Music director", "Singers") with its people as clickable chips. Each chip opens the person page
// with that role. People of one name stay separate chips and carry a detail ("b. 1923") so they can be told apart.
//
// API (owned by the album/soundtrack page package; the song and film pages reuse it):
//   MusicGraphCreditPerson(id: MusicEntityID, name: String, detail: String? = nil, count: Int = 0, tag: MusicGraphTag? = nil)
//   MusicGraphCreditRow(role: String, people: [MusicGraphCreditPerson], onOpen: @escaping (MusicGraphCreditPerson) -> Void)
// `count` is the number of songs the person is credited on (shown as "· 4"); 0 shows nothing. The chips wrap onto further lines; the role label is
// a heading for VoiceOver and the chips read "Mukesh, 4 songs, Singer".

struct MusicGraphCreditPerson: Hashable, Identifiable, Sendable {
    var id: MusicEntityID
    var name: String
    var detail: String?
    var count: Int
    var tag: MusicGraphTag?
    init(id: MusicEntityID, name: String, detail: String? = nil, count: Int = 0, tag: MusicGraphTag? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.count = count; self.tag = tag
    }
}

struct MusicGraphCreditRow: View {
    let role: String
    let people: [MusicGraphCreditPerson]
    let onOpen: (MusicGraphCreditPerson) -> Void
    /// How many names a row shows before "+N more" (a film can credit dozens; the rest is one tap away, not a wall of chips).
    static let collapsedLimit = 6
    @State private var expanded = false

    init(role: String, people: [MusicGraphCreditPerson], onOpen: @escaping (MusicGraphCreditPerson) -> Void) {
        self.role = role; self.people = people; self.onOpen = onOpen
    }

    private var shown: [MusicGraphCreditPerson] { expanded || people.count <= Self.collapsedLimit + 1 ? people : Array(people.prefix(Self.collapsedLimit)) }
    private var hidden: Int { people.count - shown.count }

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: role).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).accessibilityAddTraits(.isHeader)
                MusicGraphFlowLayout(spacing: MusicSpace.xs) {
                    ForEach(shown) { p in MusicGraphCreditChip(person: p, role: role) { onOpen(p) } }
                    if hidden > 0 {
                        Button { withAnimation(.easeOut(duration: 0.2)) { expanded = true } } label: { Text(verbatim: Localized.string("+%d more", hidden)) }
                            .musicButton(.tertiary, size: .compact).accessibilityLabel(Localized.string("Show %d more in %@", hidden, role)).atlasCovers("control.music.graphCreditChip")
                    } else if expanded && people.count > Self.collapsedLimit + 1 {
                        Button { withAnimation(.easeOut(duration: 0.2)) { expanded = false } } label: { Text(verbatim: Localized.string("Show less")) }
                            .musicButton(.tertiary, size: .compact).atlasCovers("control.music.graphCreditChip")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct MusicGraphCreditChip: View {
    let person: MusicGraphCreditPerson
    let role: String
    let action: () -> Void

    private var spoken: String {
        var parts = [person.name]
        if let d = person.detail, !d.isEmpty { parts.append(d) }
        if person.count > 0 { parts.append(Localized.plural(person.count, one: "%@ song", other: "%@ songs")) }
        parts.append(role)
        if let t = person.tag { parts.append(t.spoken) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.xxs) {
                // A small round photo (their picture when one is found and verified, else a designed tile with their initials).
                MusicCoverImage(thumbs: [], artworkClass: .trackThumb, size: MusicSpace.lg, corner: MusicCardGeometry.roundCorner, seed: person.name,
                                initials: MusicArtistPortrait.initials(person.name), subject: .card(.person, name: person.name, entity: person.id))
                    .accessibilityHidden(true)
                Text(verbatim: person.name).lineLimit(1)
                if let d = person.detail, !d.isEmpty { Text(verbatim: d).foregroundStyle(ColorTokens.textTertiary).lineLimit(1) }
                // "9" alone read like the number of their albums: it is how many of THIS album's songs they are credited on, so it says so.
                if person.count > 0 { Text(verbatim: "· " + Localized.plural(person.count, one: "%@ song", other: "%@ songs")).foregroundStyle(ColorTokens.textTertiary) }
                if let t = person.tag { Image(systemName: t.symbol).font(.system(size: MusicIconSize.tiny)).foregroundStyle(ColorTokens.textTertiary) }
            }
        }
        .musicButton(.chip, size: .compact)
        .accessibilityLabel(spoken)
        .help(person.tag.map { person.name + ": " + $0.title } ?? person.name)
        .atlas("control.music.graphCreditChip")
    }
}

/// Lays children out in rows that wrap (no fixed widths, leading to trailing). Shared by the credit chips and the actor filter.
struct MusicGraphFlowLayout: Layout {
    var spacing: CGFloat = MusicSpace.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing; rowHeight = max(rowHeight, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowHeight = max(rowHeight, s.height)
        }
    }
}
