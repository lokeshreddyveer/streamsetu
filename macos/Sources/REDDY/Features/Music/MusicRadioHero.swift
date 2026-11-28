import SwiftUI

// The top of the Radio page: the "Start a station" field with its suggestions, and the "Now on radio" card with the playing station's seeds,
// thumbs, mode and stop. Both talk to the radio service only; the page decides nothing about songs.

/// "Now on radio": the station that plays, the song, its seeds as chips that open them, the thumbs, the mode and the two things a station can do.
struct MusicNowOnRadioCard: View {
    @Bindable var hub: MusicHub
    @State private var working = false
    @Environment(\.musicLayoutClass) private var layoutClass
    @Environment(\.reddyAccent) private var accent

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MusicCorner.cardLarge, style: .continuous) }

    var body: some View {
        let radio = hub.radio
        if let st = radio.activeStation, radio.isActive || radio.isBusy {
            let layout = layoutClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: MusicSpace.md)) : AnyLayout(HStackLayout(alignment: .top, spacing: MusicSpace.md))
            layout {
                artwork(st)
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Label { Text(verbatim: Localized.string("Now on radio")) } icon: { MusicIcon(glyph: .radio, size: 14, tint: .accent) }
                        .musicText(.caption).foregroundStyle(accent)
                    Text(verbatim: st.name).font(Typography.title).lineLimit(2).accessibilityAddTraits(.isHeader)
                    nowLine(radio)
                    chips(st)
                    modes(st)
                    actions(st, radio)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(MusicSpace.md)
            .background(ColorTokens.surface, in: shape)
            .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
            .accessibilityElement(children: .contain)
            .atlas("control.music.radioNowCard")
        }
    }

    /// The song's cover; the frame is set first and the picture drawn inside it.
    @ViewBuilder private func artwork(_ st: RadioStation) -> some View {
        Group {
            if let song = hub.player.current, hub.radio.isActive {
                MusicCoverImage(thumbs: song.thumbnails, artworkClass: .tile, corner: MusicCorner.card, seed: song.uid, subject: .derive(song))
            } else {
                RadioMosaic(station: st).clipShape(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
            }
        }
        .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous)).accessibilityHidden(true)
    }

    @ViewBuilder private func nowLine(_ radio: RadioService) -> some View {
        if radio.isTroubled {
            HStack(spacing: MusicSpace.xs) {
                Text(verbatim: Localized.string("Having trouble finding songs.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                Button(Localized.string("Retry")) { radio.retry() }.musicButton(.secondary, size: .compact).atlas("control.music.radioRetry")
            }
        } else if radio.isBusy {
            HStack(spacing: MusicSpace.xs) {
                ProgressView().controlSize(.small)
                Text(verbatim: Localized.string("Starting your station")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            }
        } else if let song = hub.player.current {
            HStack(spacing: 0) {
                Button { hub.open(MusicFillRuntime.songID(song)) } label: { Text(verbatim: song.title).lineLimit(1) }
                    .buttonStyle(.plain).accessibilityLabel(Localized.string("Go to song %@", song.title)).atlas("control.music.radioNowSong")
                ForEach(Array(song.artists.prefix(3).enumerated()), id: \.offset) { i, a in
                    Text(verbatim: i == 0 ? " · " : ", ")
                    Button { hub.open(.artist(MusicLinks.artist(a, providerID: song.providerID))) } label: { Text(verbatim: a.name).lineLimit(1) }
                        .buttonStyle(.plain).accessibilityLabel(Localized.string("Go to artist %@", a.name)).atlas("control.music.radioNowArtist")
                }
            }
            .musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
        }
    }

    private func chips(_ st: RadioStation) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MusicSpace.xs) { ForEach(st.seeds) { RadioSeedChip(hub: hub, seed: $0) } }
        }
    }

    private func modes(_ st: RadioStation) -> some View {
        HStack(spacing: MusicSpace.xs) {
            ForEach(RadioMode.allCases) { m in
                MusicChip(title: m.title, selected: st.mode == m) { hub.radio.setMode(st.id, m) }
                    .musicTooltip(verbatim: m.blurb).atlas("control.music.radioMode")
            }
        }
    }

    private func actions(_ st: RadioStation, _ radio: RadioService) -> some View {
        HStack(spacing: MusicSpace.xs) {
            if let song = hub.player.current { MusicRadioThumbs(hub: hub, track: song, showsTired: true) }
            Spacer(minLength: MusicSpace.xs)
            MusicButton(title: "New station", systemImage: "arrow.triangle.2.circlepath", variant: .secondary, busy: working, atlas: "control.music.radioNew") {
                working = true
                Task { await radio.restart(st.id); working = false }
            }
            MusicButton(title: "Stop station", systemImage: "stop.fill", variant: .secondary, atlas: "control.music.radioStop") { radio.stop() }
        }
    }
}

/// The "Start a station" field: type an artist, a song, a genre or a language. Suggestions come from the same service as the search page; Return
/// starts a station from the words, a suggestion starts it from that artist or song.
struct MusicRadioSeedField: View {
    @Bindable var hub: MusicHub
    let onStart: ([RadioSeed]) -> Void
    @State private var text = ""
    @State private var suggest = MusicSuggestModel()
    @State private var resolving = false
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    private var typed: String { MusicSuggest.trimmed(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(accent).accessibilityHidden(true)
                TextField(Localized.string("Start a station: an artist, song, genre or language"), text: $text)
                    .textFieldStyle(.plain).focused($focused).onSubmit { startTyped() }
                    .accessibilityLabel(Localized.string("Start a station")).atlas("control.music.radioSeedField")
                if resolving { ProgressView().controlSize(.small) }
                else if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ColorTokens.textTertiary) }
                        .buttonStyle(.plain).accessibilityLabel(Localized.string("Clear")).atlas("control.music.radioSeedClear")
                }
                Button(Localized.string("Start")) { startTyped() }.musicButton(.primary, size: .compact).disabled(typed.isEmpty || resolving)
                    .atlas("control.music.radioSeedStart")
            }
            .padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.xs)
            .background(ColorTokens.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? accent : ColorTokens.line, lineWidth: focused ? 1.5 : 0.75))
            if focused || !text.isEmpty, !typed.isEmpty { suggestions }
        }
        .onChange(of: text) { _, new in suggest.update(typed: new, registry: hub.registry) }
        .onDisappear { suggest.cancel() }
    }

    @ViewBuilder private var suggestions: some View {
        let artists = distinctArtists
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: "magnifyingglass", title: Localized.string("Start a station from “%@”", typed), subtitle: nil, thumbs: [], id: "typed") { startTyped() }
            ForEach(suggest.local.prefix(4), id: \.self) { s in
                row(symbol: "magnifyingglass", title: s, subtitle: nil, thumbs: [], id: "local:" + s) { text = s; startTyped() }
            }
            ForEach(artists, id: \.uid) { a in
                row(symbol: "person.fill", title: a.name, subtitle: Localized.string("Artist"), thumbs: a.thumbnails, id: "artist:" + a.uid) { onStart([.artist(a)]); text = "" }
            }
            ForEach(suggest.tracks.prefix(4)) { t in
                row(symbol: "music.note", title: t.title, subtitle: t.artistLine, thumbs: t.thumbnails, id: "song:" + t.uid) { onStart([.song(t)]); text = "" }
            }
        }
        .padding(MusicSpace.xs)
        .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
    }

    /// The artists of the suggested songs, once each.
    private var distinctArtists: [MusicArtist] {
        var seen = Set<String>()
        var out: [MusicArtist] = []
        for t in suggest.tracks {
            for r in t.artists.prefix(1) where !r.id.isEmpty && !MusicArtistFiller.isFiller(r.name) && seen.insert(MusicCategory.normalise(r.name)).inserted {
                out.append(MusicLinks.artist(r, providerID: t.providerID))
            }
        }
        return Array(out.prefix(3))
    }

    private func row(symbol: String, title: String, subtitle: String?, thumbs: [MusicThumbnail], id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.sm) {
                Group {
                    if thumbs.isEmpty { Image(systemName: symbol).foregroundStyle(ColorTokens.textTertiary).frame(width: 36, height: 36) }
                    else {
                        MusicCoverImage(thumbs: thumbs, artworkClass: .tile, corner: MusicCorner.card, seed: id)
                            .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).musicText(.body).lineLimit(1).foregroundStyle(ColorTokens.textPrimary)
                    if let subtitle, !subtitle.isEmpty { Text(verbatim: subtitle).musicText(.caption).lineLimit(1).foregroundStyle(ColorTokens.textSecondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain).atlas("control.music.radioSeedSuggestion")
    }

    private func startTyped() {
        let words = typed
        guard !words.isEmpty, !resolving else { return }
        resolving = true
        Task {
            let seed = await RadioSeedResolver.resolve(words, hub: hub)
            resolving = false
            if let seed { text = ""; onStart([seed]) }
        }
    }
}
