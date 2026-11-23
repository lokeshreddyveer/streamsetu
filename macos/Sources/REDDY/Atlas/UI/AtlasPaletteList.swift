import SwiftUI

/// "Ask Setu" and "Actions and screens" for a typed query, as plain rows. The Mac top search and the iPhone/iPad Search tab both place this once; what a tap does comes in as closures, so it knows no router.
struct AtlasPaletteList: View {
    let query: String
    let platform: AtlasPlatforms
    var appStore = false
    var showAsk = true
    let open: (String) -> Void
    let show: (String) -> Void
    let ask: (String) -> Void
    @State private var rows: [AtlasPaletteRow] = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if showAsk && !trimmed.isEmpty { askRow }
            if !rows.isEmpty {
                Text("ACTIONS AND SCREENS").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in row(r, index: i + 1, of: rows.count) }
            }
        }
        .task(id: query) { rows = AtlasPaletteSource.rows(for: query, engine: Atlas.engine, platform: platform, appStore: appStore) }
    }

    private var askRow: some View {
        let question = AtlasPaletteSource.isQuestion(trimmed)
        return Button { ask(trimmed) } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").frame(width: 20).foregroundStyle(Color.accentColor)
                Text(AtlasPaletteSource.askTitle(trimmed)).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                #if os(macOS)
                Text(question ? "↩" : "⌘↩").font(.caption).foregroundStyle(.secondary)
                #else
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.accentColor.opacity(question ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Ask Setu: \(trimmed)").accessibilityHint("Opens Setu with this question")
    }

    private func row(_ r: AtlasPaletteRow, index: Int, of count: Int) -> some View {
        HStack(spacing: 8) {
            Button { r.canOpen ? open(r.id) : show(r.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: r.symbol).frame(width: 20).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.body.weight(.medium)).lineLimit(1)
                        if !r.breadcrumb.isEmpty { Text(r.breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    if let k = r.shortcut { Text(k).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(r.title). \(r.breadcrumb)").accessibilityValue("Row \(index) of \(count)\(r.shortcut.map { ", shortcut \($0)" } ?? "")")
            Button { show(r.id) } label: { Label("Show me", systemImage: "scope").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("Show me").accessibilityLabel("Show me \(r.title)")
        }
        .padding(.horizontal, 12).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
