import SwiftUI

/// Every keyboard shortcut in one place. Opened from Help > Keyboard Shortcuts.
struct ShortcutsView: View {
    private struct Row: Identifiable { let keys: String; let what: String; var id: String { keys + what } }
    private struct Group: Identifiable { let title: String; let rows: [Row]; var id: String { title } }

    private let groups: [Group] = AtlasShortcuts.groups.map { g in Group(title: g.title, rows: g.rows.map { Row(keys: $0.keys, what: $0.what) }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Keyboard Shortcuts").font(Typography.title)
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(g.title).font(Typography.heading)
                        ForEach(g.rows) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(r.keys).font(Typography.mono).frame(width: 150, alignment: .leading)
                                Text(r.what).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 600).background(ColorTokens.background)
    }
}
