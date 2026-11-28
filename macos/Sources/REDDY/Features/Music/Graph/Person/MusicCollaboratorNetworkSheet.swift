import SwiftUI

/// A person in the middle and their most frequent collaborators around them. Choosing one moves the middle to them; "Open page" goes to their page.
struct MusicCollaboratorNetworkSheet: View {
    let hub: MusicHub
    /// The person whose page opened this sheet; "Open page" is not offered for them (they are already there).
    private let person: MusicEntityID
    @State private var path: [MusicEntityID]
    @State private var network: MusicCollaboratorNetwork?
    @State private var loading = true
    let close: () -> Void
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub, person: MusicEntityID, close: @escaping () -> Void) {
        self.hub = hub; self.person = person; self.close = close; _path = State(initialValue: [person])
    }

    private var current: MusicEntityID { path.last! }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Collaborator network")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                if path.count > 1 { Button(Localized.string("Back")) { path.removeLast() }.musicButton(.secondary, size: .compact).atlas("control.music.networkBack") }
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.networkClose")
            }
            if loading { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity, minHeight: 200) }
            else if let n = network, !n.nodes.isEmpty {
                wheel(n)
                Text(Localized.plural(n.worksChecked, one: "Looked through %@ work.", other: "Looked through %@ works.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
                if n.center != person { Button(Localized.string("Open page")) { let id = n.center; close(); hub.open(id) }.musicButton(.primary, size: .compact).atlas("control.music.networkOpen") }
            } else {
                Text(Localized.string("No collaborators are known for this person yet.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560)
        .task(id: current) {
            loading = true
            let loaded = await MusicCollaboratorNetwork.load(for: current, store: MusicEntityRuntime.shared.center.store.graph)
            // A slower load for a node the person already left must not overwrite the one they are looking at.
            guard !Task.isCancelled else { return }
            network = loaded
            loading = false
        }
    }

    private func wheel(_ n: MusicCollaboratorNetwork) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 440)
            let r = side * 0.36
            let c = CGPoint(x: geo.size.width / 2, y: side / 2)
            ZStack {
                ForEach(Array(n.nodes.enumerated()), id: \.element.id) { i, _ in
                    let p = MusicRelationshipWheel.point(index: i, of: n.nodes.count)
                    Path { path in path.move(to: c); path.addLine(to: CGPoint(x: c.x + p.x * r, y: c.y + p.y * r)) }
                        .stroke(ColorTokens.lineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                }
                Circle().fill(ColorTokens.surface).overlay(Circle().strokeBorder(accent.opacity(0.7), lineWidth: 2))
                    .overlay(Text(verbatim: n.centerName).font(Typography.captionMedium).multilineTextAlignment(.center).lineLimit(3).padding(8).foregroundStyle(ColorTokens.textPrimary))
                    .frame(width: side * 0.26, height: side * 0.26).position(c)
                ForEach(Array(n.nodes.enumerated()), id: \.element.id) { i, node in
                    let p = MusicRelationshipWheel.point(index: i, of: n.nodes.count)
                    Button { path.append(node.id) } label: {
                        VStack(spacing: 1) {
                            Text(verbatim: node.name).font(Typography.captionMedium).lineLimit(2).multilineTextAlignment(.center)
                            Text(Localized.plural(node.shared, one: "%@ work together", other: "%@ works together")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center)
                        }
                        .frame(width: 104).padding(.vertical, 8).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorTokens.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ColorTokens.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain).atlas("control.music.networkNode")
                    .position(x: c.x + p.x * r, y: c.y + p.y * r)
                }
            }
        }
        .frame(height: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Localized.string("Collaborator network"))
    }
}
