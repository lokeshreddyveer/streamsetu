import SwiftUI

/// One thing on a timeline: a film, a series, an album, a song or a milestone. It carries only what the line itself draws; the picture and what a
/// tap does belong to the screen that uses the line.
struct SetuTimelineNode: Identifiable, Hashable, Sendable {
    let id: String
    /// What goes under the rail: a year, usually.
    var label: String
    var title: String
    var subtitle: String?
    /// Height over width of the picture: 1.5 for a poster, 1 for a cover or an icon.
    var aspect: CGFloat = 1.5
    /// How many more things share this node ("+3"); zero draws nothing.
    var extra: Int = 0
}

/// A run of nodes under one heading, such as a decade.
struct SetuTimelineSection: Identifiable, Hashable, Sendable {
    let id: String
    var title: String?
    var nodes: [SetuTimelineNode]
}

/// The shared timeline of StreamSetu: things in the order they happened on one numbered line, the line lit up to the chosen point. The Movies screen's franchise
/// and an artist's career are the same component, so they look and behave the same. The caller draws each picture (and makes it tappable) in `cell`.
///
/// - `litThrough`: the flat position the line is lit up to; nil lights the whole line.
/// - `current`: the flat position that is marked as the open one, if any.
struct SetuTimeline<Cell: View>: View {
    let sections: [SetuTimelineSection]
    var litThrough: Int?
    var current: Int?
    var posterWidth: CGFloat = 110
    @ViewBuilder var cell: (_ node: SetuTimelineNode, _ here: Bool) -> Cell

    private var flat: [SetuTimelineNode] { sections.flatMap(\.nodes) }

    var body: some View {
        let order = Dictionary(uniqueKeysWithValues: flat.enumerated().map { ($1.id, $0) })
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let t = section.title, !t.isEmpty {
                        Text(verbatim: t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(section.nodes) { node in
                                column(node, index: order[node.id] ?? 0)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func lit(_ index: Int) -> Bool { litThrough.map { index <= $0 } ?? true }

    private func column(_ node: SetuTimelineNode, index: Int) -> some View {
        let here = current == index
        return VStack(spacing: 10) {
            cell(node, here)
                .frame(width: posterWidth, height: posterWidth * node.aspect)
                .scaleEffect(here ? 1 : 0.94, anchor: .bottom)
                .opacity(here ? 1 : 0.88)
                .shadow(color: here ? ColorTokens.accent.opacity(0.45) : .clear, radius: 14, y: 4)
            rail(index, here: here)
            VStack(spacing: 2) {
                Text(verbatim: node.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(here ? ColorTokens.accent : .primary)
                Text(verbatim: node.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                if let s = node.subtitle, !s.isEmpty {
                    Text(verbatim: s).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if node.extra > 0 {
                    Text(verbatim: "+\(node.extra)").font(.system(size: 10, weight: .semibold)).foregroundStyle(ColorTokens.accent)
                }
            }
            .frame(width: posterWidth)
        }
        .frame(width: posterWidth + 20)
    }

    /// One piece of the line through the numbered dot; the part up to the lit point is in the accent colour.
    private func rail(_ index: Int, here: Bool) -> some View {
        let accent = ColorTokens.accent, dim = Color.secondary.opacity(0.3)
        let first = index == 0, last = index == flat.count - 1
        return ZStack {
            HStack(spacing: 0) {
                Rectangle().fill(first ? .clear : (lit(index) ? accent : dim)).frame(height: 3)
                Rectangle().fill(last ? .clear : (lit(index + 1) ? accent : dim)).frame(height: 3)
            }
            Text(verbatim: "\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(lit(index) ? Color.white : .secondary)
                .frame(width: here ? 28 : 22, height: here ? 28 : 22)
                .background(Circle().fill(lit(index) ? accent : Color.secondary.opacity(0.25)))
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}
