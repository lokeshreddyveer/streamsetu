import SwiftUI

// The thumbs of a station: shown beside the heart in the player bar, the expanded player and the Now Playing panel while a station plays, and
// nowhere else. They talk only to the radio service; the service likes the song for a thumbs up and skips for a thumbs down.

extension MusicHub {
    /// The one radio service (stations, thumbs, refill). Everything that needs it reaches it through the hub.
    var radio: RadioService { RadioService.shared }
}

struct MusicRadioThumbs: View {
    @Bindable var hub: MusicHub
    let track: MusicTrack
    /// The expanded player draws on a dark picture: white ink instead of the theme's.
    var onDark = false
    /// Also shows the "Not for a while" button (the bar keeps it in its menu).
    var showsTired = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        if hub.radio.isActive {
            let given = hub.radio.feedback(for: track.uid)
            HStack(spacing: 0) {
                thumb("hand.thumbsup", filled: "hand.thumbsup.fill", on: given == .up, label: Localized.string("Thumbs up"), atlas: "control.music.radioThumbUp") { hub.radio.thumbsUp(track) }
                thumb("hand.thumbsdown", filled: "hand.thumbsdown.fill", on: given == .down, label: Localized.string("Thumbs down, skip and don't play on this station"),
                      atlas: "control.music.radioThumbDown") { hub.radio.thumbsDown(track) }
                if showsTired {
                    thumb("moon.zzz", filled: "moon.zzz.fill", on: given == .tired, label: Localized.string("Not for a while"), atlas: "control.music.radioNotForAWhile") { hub.radio.notForAWhile(track) }
                }
            }
            // A guest in a listening room follows the host: thumbs-down skips the song for everyone.
            .musicRoomLocked(hub.room.controlsLocked)
        }
    }

    private func thumb(_ symbol: String, filled: String, on: Bool, label: String, atlas id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? filled : symbol).font(.system(size: MusicIconSize.large))
                .foregroundStyle(on ? accent : (onDark ? Color.white.opacity(0.8) : ColorTokens.textSecondary))
                .frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
        }.atlas("control.music.radioThumb")
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .musicTooltip(verbatim: label)
        .atlas(id)
    }
}
