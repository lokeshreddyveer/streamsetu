import SwiftUI

// The shuffle and autoplay controls: the menu on the bar's shuffle button (secondary click or long press), the same entries in the queue panel,
// and the "Shuffle and autoplay" block in Settings > Playback. One content view serves all three, so they can never disagree.

/// Menu entries: the three shuffle modes, Reshuffle, and the Autoplay switch. Put it in a `.contextMenu` or a `Menu`.
struct MusicShuffleMenuContent: View {
    let hub: MusicHub
    private var player: MusicPlayer { hub.player }

    var body: some View {
        Section(Localized.string("Shuffle")) {
            ForEach(MusicShuffleMode.allCases) { mode in
                Button { player.shuffleMode = mode; if !player.shuffle { player.shuffle = true } } label: {
                    if player.shuffleMode == mode { Label(mode.title, systemImage: "checkmark") } else { Text(verbatim: mode.title) }
                }
                .atlas("control.music.shuffleMode")
            }
            Button(Localized.string("Reshuffle"), systemImage: "arrow.triangle.2.circlepath") { player.reshuffle() }
                .disabled(!player.shuffle).atlas("control.music.shuffleReshuffle")
        }
        Section {
            Toggle(Localized.string("Autoplay"), isOn: Binding(get: { hub.library.settings.endlessPlayback }, set: { player.setAutoplay($0) }))
                .atlas("control.music.autoplayMenuToggle")
        }
    }
}

/// A small chevron menu for the queue panel header: names the active mode ("Shuffled (Smart)") and opens the same entries.
struct MusicShuffleQueueMenu: View {
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let p = hub.player
        Menu { MusicShuffleMenuContent(hub: hub) } label: {
            Text(verbatim: p.shuffle ? Localized.string("Shuffled (%@)", p.shuffleMode.shortTitle) : Localized.string("Shuffle off"))
                .font(Typography.captionMedium).foregroundStyle(p.shuffle ? accent : ColorTokens.textSecondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(Localized.string("Choose how shuffle orders the queue, and turn Autoplay on or off."))
        .accessibilityLabel(Localized.string("Shuffle options"))
        .atlas("control.music.shuffleQueueMenu")
    }
}

/// The line under the queue's Autoplay divider: what autoplay follows.
struct MusicAutoplayHeading: View {
    let seedTitle: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "infinity")
            VStack(alignment: .leading, spacing: 0) {
                Text(Localized.string("Autoplay")).font(Typography.captionMedium)
                if let s = seedTitle, !s.isEmpty {
                    Text(verbatim: Localized.string("Related to %@", s)).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(ColorTokens.textSecondary)
    }
}

/// Settings > Playback > "Shuffle and autoplay".
struct MusicShuffleAutoplaySettingsGroup: View {
    let hub: MusicHub

    var body: some View {
        MusicSettingsGroup(title: Localized.string("Shuffle and autoplay"),
                           footer: Localized.string("Autoplay continues with related songs when your song, album or playlist ends: same artist, film, music director and language first.")) {
            MusicPickerRow(title: Localized.string("Shuffle style"), info: MusicShuffleMode.allCases.map { $0.shortTitle + ": " + $0.detail }.joined(separator: " "),
                           selection: Binding(get: { hub.player.shuffleMode.rawValue }, set: { if let m = MusicShuffleMode(rawValue: $0) { hub.player.shuffleMode = m } }),
                           options: MusicShuffleMode.allCases.map { ($0.rawValue, $0.title) })
            MusicToggleRow(title: Localized.string("Autoplay"),
                           info: Localized.string("When the queue ends, related songs keep playing. Songs you queue always come first, and autoplay songs are marked so you can remove or keep each one."),
                           isOn: Binding(get: { hub.library.settings.endlessPlayback }, set: { hub.player.setAutoplay($0) }))
        }
    }
}
