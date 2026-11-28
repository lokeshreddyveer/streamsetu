import SwiftUI
import AppKit

/// The Videos destination of a film: the film's official videos by kind (trailers, teasers, clips, featurettes, behind the scenes) as links that open in the
/// person's browser, and below them the music videos the music service itself states for the film's songs (those play in the player). A film video is never played
/// through the music player, and nothing is searched for: a kind with no video is not drawn.
struct MusicFilmVideosSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub

    var body: some View {
        let videos = model.overview?.videos ?? []
        let music = model.musicVideos
        VStack(alignment: .leading, spacing: MusicSpace.lg) {
            ForEach(MusicFilmVideoKind.allCases, id: \.self) { kind in
                let list = MusicFilmVideos.of(kind, in: videos)
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        Text(verbatim: MusicFilmWording.videoKindTitle(kind)).font(Typography.title).accessibilityAddTraits(.isHeader)
                        ForEach(list) { v in row(v, kind: kind) }
                    }
                }
            }
            if !music.isEmpty {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Text(verbatim: Localized.string("Music videos")).font(Typography.title).accessibilityAddTraits(.isHeader)
                    MusicTrackList(hub: hub, tracks: music, showsTools: false, numbered: false, canSort: false, showsAlbumByDefault: false, presorted: true)
                }
            }
            if videos.isEmpty && music.isEmpty {
                Text(verbatim: model.section(MusicFilmSectionKey.overview).phase == .loaded ? Localized.string("No videos are available for this film.") : Localized.string("Loading details..."))
                    .musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private func row(_ v: MusicFilmVideo, kind: MusicFilmVideoKind) -> some View {
        let title = v.name.isEmpty ? MusicFilmWording.videoKindTitle(kind) : v.name
        return Button { if let u = v.url { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: "play.rectangle").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary).accessibilityHidden(true)
                Text(verbatim: title).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .musicText(.body).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight().frame(maxWidth: 640)
        .accessibilityLabel(title).atlas("control.music.filmVideoLink")
    }
}

/// The chips that switch the Songs and Albums tabs between the film's own music and each dubbed edition. Drawn only when the film has a dubbed edition.
struct MusicFilmLanguageChips: View {
    let options: [MusicFilmLanguageFilter]
    @Binding var selection: MusicFilmLanguageFilter

    var body: some View {
        if !options.isEmpty {
            MusicChipFlow(spacing: MusicSpace.xs) {
                ForEach(options, id: \.self) { o in MusicChip(title: MusicFilmWording.languageFilterTitle(o), selected: selection == o) { selection = o } }
            }
        }
    }
}

/// The search field of the Crew tab.
struct MusicFilmCrewSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: "magnifyingglass").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            TextField(Localized.string("Search the crew"), text: $text).textFieldStyle(.plain).musicText(.body)
                .accessibilityLabel(Localized.string("Search the crew")).atlas("control.music.filmCrewSearch")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(MusicTokens.iconSmall) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel(Localized.string("Clear")).atlas("control.music.filmCrewSearchClear")
            }
        }
        .padding(.horizontal, MusicSpace.sm).frame(maxWidth: 320).frame(height: MusicTokens.hitTarget)
        .background(ColorTokens.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(ColorTokens.line, lineWidth: 0.75))
    }
}
