import SwiftUI

/// The moods and examples as tappable chips.
struct SearchIdeasPanel: View {
    var pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you in the mood for?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: SearchIdeas.moods, pick: pick)
            Text("Or try").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SearchIdeas.examples) { e in
                    Button { pick(e.query) } label: { Label(e.label, systemImage: e.symbol).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .buttonStyle(.plain).padding(.vertical, 3).atlas("control.search.idea")
                }
            }
        }
        .padding(14)
    }
}

private struct FlowChips: View {
    let items: [SearchIdea]
    var pick: (String) -> Void
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r]) { i in
                        Button { pick(i.query) } label: {
                            Label(i.label, systemImage: i.symbol).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6).background(Color.accentColor.opacity(0.14), in: Capsule())
                        }.buttonStyle(.plain).atlas("control.search.idea")
                    }
                }
            }
        }
    }
}
