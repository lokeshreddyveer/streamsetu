import SwiftUI

/// The quiet line a page shows while the full list of a person's films and albums (or a film's soundtracks) is still being fetched. Nothing to tap, so
/// no Atlas marker; the spinner is hidden from VoiceOver and the sentence is the label. It disappears as soon as the run ends.
struct MusicCompletenessLine: View {
    let id: MusicEntityID
    var tracker = MusicCompletenessTracker.shared

    var body: some View {
        if tracker.isRunning(id) {
            HStack(spacing: MusicSpace.xs) {
                MusicLoadingIcon(size: MusicIconSize.small).accessibilityHidden(true)
                Text(MusicCompletenessWording.loading(for: id.kind)).musicText(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

enum MusicCompletenessWording {
    static func loading(for kind: MusicEntityKind) -> String {
        switch kind {
        case .film, .series: Localized.string("Loading all soundtracks…")
        case .album, .release: Localized.string("Loading other editions…")
        default: Localized.string("Loading full filmography…")
        }
    }
}
