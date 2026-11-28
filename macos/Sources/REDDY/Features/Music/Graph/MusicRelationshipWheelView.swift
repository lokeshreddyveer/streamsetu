import SwiftUI

/// The song in the middle and who and what it is connected to around it. Each node opens that person's page on the role shown, or the film.
struct MusicRelationshipWheelView: View {
    let page: MusicSongPageModel
    let title: String
    let nodes: [MusicWheelNode]
    @Environment(\.reddyAccent) private var accent

    private func caption(_ k: MusicWheelNode.Kind) -> String {
        switch k {
        case .singer: Localized.string("Singer")
        case .composer: Localized.string("Composer")
        case .lyricist: Localized.string("Lyricist")
        case .producer: Localized.string("Producer")
        case .musicians: Localized.string("Musicians")
        case .film: Localized.string("Movie")
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 420)
            let r = side * 0.36
            let c = CGPoint(x: geo.size.width / 2, y: side / 2)
            ZStack {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                    let p = MusicRelationshipWheel.point(index: i, of: nodes.count)
                    Path { path in path.move(to: c); path.addLine(to: CGPoint(x: c.x + p.x * r, y: c.y + p.y * r)) }
                        .stroke(ColorTokens.lineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                }
                Circle().fill(ColorTokens.surface).overlay(Circle().strokeBorder(accent.opacity(0.7), lineWidth: 2))
                    .overlay(VStack(spacing: 2) {
                        Image(systemName: "waveform").font(.system(size: 18, weight: .semibold))
                        Text(verbatim: title).font(Typography.captionMedium).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 6)
                    }.foregroundStyle(ColorTokens.textPrimary))
                    .frame(width: side * 0.26, height: side * 0.26).position(c)
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                    let p = MusicRelationshipWheel.point(index: i, of: nodes.count)
                    node(n).position(x: c.x + p.x * r, y: c.y + p.y * r)
                }
            }
        }
        .frame(height: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Localized.string("How this song is connected"))
    }

    @ViewBuilder private func node(_ n: MusicWheelNode) -> some View {
        let label = VStack(spacing: 1) {
            Text(verbatim: caption(n.kind)).font(Typography.eyebrow).foregroundStyle(ColorTokens.textTertiary)
            Text(verbatim: n.film?.displayName ?? n.people.prefix(2).map(\.name).joined(separator: ", ")).font(Typography.captionMedium).lineLimit(2).multilineTextAlignment(.center)
            if n.extra > 0 { Text(verbatim: "+\(n.extra)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
        }
        .frame(width: 110).padding(.vertical, 8).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorTokens.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ColorTokens.lineStrong, lineWidth: 1))
        if let film = n.film {
            Button { page.open(film.id) } label: { label }.buttonStyle(.plain).atlas("control.music.wheelFilm")
        } else if n.people.count == 1, let p = n.people.first {
            Button { page.open(p.id, role: p.role) } label: { label }.buttonStyle(.plain).atlas("control.music.wheelPerson")
        } else {
            Menu {
                ForEach(n.people) { p in Button(p.displayName) { page.open(p.id, role: p.role) }.atlas("control.music.wheelPersonChoice") }
            } label: { label }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).atlas("control.music.wheelPeople")
        }
    }
}
