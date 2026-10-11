import SwiftUI

/// Every keyboard shortcut in one place. Opened from Help > Keyboard Shortcuts.
struct ShortcutsView: View {
    private struct Row: Identifiable { let keys: String; let what: String; var id: String { keys + what } }
    private struct Group: Identifiable { let title: String; let rows: [Row]; var id: String { title } }

    private let groups: [Group] = [
        Group(title: "Moving around", rows: [
            Row(keys: "⌘1 – ⌘5", what: "Home, Live TV, Movies, Series, TV Guide"),
            Row(keys: "⌘K", what: "Search everything"),
            Row(keys: "⌘F", what: "Search within this screen"),
            Row(keys: "⌘N", what: "Add a playlist"),
            Row(keys: "⌘R", what: "Refresh all playlists"),
            Row(keys: "Esc", what: "Close the top-most thing: search, a panel, a detail page, then the player"),
            Row(keys: "Tab / ⇧Tab", what: "Move between buttons and cards (turn on Keyboard navigation in System Settings > Keyboard)"),
            Row(keys: "Return", what: "Open or play what is highlighted"),
            Row(keys: "← →", what: "In the TV Guide: move the time window by 30 minutes"),
        ]),
        Group(title: "Playing", rows: [
            Row(keys: "Space", what: "Play or pause"),
            Row(keys: "F", what: "Full screen on or off"),
            Row(keys: "M", what: "Mute"),
            Row(keys: "← →", what: "Back or forward 10 seconds (full screen, movies and episodes)"),
            Row(keys: "↑ ↓", what: "Volume for movies; previous or next channel for live TV (full screen)"),
            Row(keys: "Page Up / Page Down", what: "Previous or next channel"),
            Row(keys: "0 – 9, Return", what: "Type a channel number, then Return to go to it"),
            Row(keys: "Tab, C or Return", what: "Open the channel list while playing live TV"),
            Row(keys: "⌘→  ⌘←", what: "Skip forward or back 10 seconds"),
            Row(keys: "⌘]  ⌘[", what: "Next or previous channel"),
            Row(keys: "⌘L", what: "Go back to the last channel"),
            Row(keys: "⌘E", what: "Next episode"),
            Row(keys: "⌘.", what: "Stop"),
            Row(keys: "⇧⌘M", what: "Open Multi-View"),
            Row(keys: "⇧⌘P", what: "Open the player in its own window"),
        ]),
    ]

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
