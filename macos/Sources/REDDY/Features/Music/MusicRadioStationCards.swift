import SwiftUI

// The cards of the Radio page: a station's cover mosaic, the station card, and the chip that shows one of its seeds and opens it.
// Artwork comes first: the cover is built from the artists the station has played (or its seeds' pictures) and never from a fixed image.

/// A station's cover: one picture, two halves or a 2x2 mosaic of the artists it plays. Each picture is drawn in an overlay of a flexible clear cell,
/// so a fill image never sets the size of the card (the click-safety rule).
struct RadioMosaic: View {
    let station: RadioStation

    var body: some View {
        let tiles = Array(station.mosaic.prefix(4))
        Group {
            switch tiles.count {
            case 0: MusicCoverFallback(seed: station.id, kind: .station)
            case 1: cell(tiles[0], 0)
            case 2: HStack(spacing: 1) { cell(tiles[0], 0); cell(tiles[1], 1) }
            default:
                VStack(spacing: 1) {
                    HStack(spacing: 1) { cell(tiles[0], 0); cell(tiles[1], 1) }
                    HStack(spacing: 1) { cell(tiles[2], 2); if tiles.count > 3 { cell(tiles[3], 3) } else { cell(tiles[0], 4) } }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func cell(_ thumbs: [MusicThumbnail], _ i: Int) -> some View {
        Color.clear
            .overlay { MusicCoverImage(thumbs: thumbs, artworkClass: .tile, corner: 0, seed: station.id + String(i)) }
            .clipped().allowsHitTesting(false)
    }
}

/// A station: cover mosaic, name, one line. The whole card starts it; a station that is playing says so instead of showing the play disc.
struct RadioStationCard: View {
    @Bindable var hub: MusicHub
    let station: RadioStation
    var width: CGFloat = MusicCardSize.standard.width
    var busy = false
    var menu: (() -> AnyView)?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous) }
    private var playing: Bool { hub.radio.activeID == station.id && hub.radio.isActive }

    private var line: String {
        if let at = station.lastPlayedAt {
            return RelativeDateTimeFormatter().localizedString(for: at, relativeTo: Date())
        }
        return station.seeds.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MusicCardGeometry.coverToText) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { RadioMosaic(station: station).scaleEffect(hovering && !reduceMotion ? MusicCardGeometry.hoverScale : 1) }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(ColorTokens.line, lineWidth: 0.75))
                    .musicHoverLift(hovering, cornerRadius: MusicCorner.card)
                    .overlay(shape.strokeBorder(accent, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
                    .overlay(alignment: .bottomTrailing) { disc.padding(MusicSpace.xs) }
                VStack(alignment: .leading, spacing: MusicCardGeometry.textSpacing) {
                    Text(verbatim: station.name).musicText(.card).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(ColorTokens.textPrimary)
                    Text(verbatim: line).musicText(.caption).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(ColorTokens.textSecondary)
                }
                .frame(minHeight: MusicCardGeometry.textBlockHeight, alignment: .top)
            }
            .frame(width: width, alignment: .leading)
            .frame(minHeight: MusicTokens.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused).focusEffectDisabled()
        .onHover { hovering = $0 }
        .musicAnimation(.hover, reduce: reduceMotion, value: hovering)
        .musicAnimation(.focus, reduce: reduceMotion, value: focused)
        .contextMenu { if let menu { menu() } }
        .musicTooltip(verbatim: Localized.string("Play %@", station.name))
        .accessibilityLabel(Localized.string("Play %@", station.name))
        .accessibilityHint(station.seeds.map(\.name).joined(separator: ", "))
        .disabled(busy)
        .atlas("control.music.radioStationCard")
    }

    private var disc: some View {
        Group {
            if busy { MusicLoadingIcon(size: MusicIconSize.small) }
            else if playing { Image(systemName: "waveform").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.onAccent(accent)) }
            else { Image(systemName: "play.fill").font(MusicTokens.iconMedium).foregroundStyle(ColorTokens.onAccent(accent)) }
        }
        .frame(width: MusicTokens.hitTarget + MusicSpace.xs, height: MusicTokens.hitTarget + MusicSpace.xs)
        .background(accent, in: Circle())
        .overlay(Circle().strokeBorder(MusicInk.hairlineOnArtwork, lineWidth: 0.75))
        .accessibilityHidden(true)
    }
}

/// One seed of a station as a chip that opens what it is: an artist opens the artist, a song its album (else its artist), a genre, language or
/// mood runs that search.
struct RadioSeedChip: View {
    @Bindable var hub: MusicHub
    let seed: RadioSeed

    private var symbol: String {
        switch seed.kind {
        case .song: "music.note"
        case .artist: "person.fill"
        case .genre: "guitars"
        case .language: "character.bubble"
        case .mood: "sparkles"
        }
    }

    var body: some View {
        MusicChip(title: seed.name, selected: false, systemImage: symbol) { open() }
            .accessibilityLabel(Localized.string("Open %@", seed.name))
            .atlas("control.music.radioSeedChip")
    }

    private func open() {
        MusicDebugLog.log("radio", "seed chip \(seed.kind.rawValue) \(seed.name)")
        switch seed.kind {
        case .artist:
            if let a = seed.artist { hub.open(.artist(a)) }
        case .song:
            if let t = seed.track {
                if let a = t.album, !a.id.isEmpty { hub.open(.album(MusicLinks.album(a, providerID: t.providerID))) }
                else if let r = MusicCompilationArtist.primary(in: t.artists) { hub.open(.artist(MusicLinks.artist(r, providerID: t.providerID))) }
            }
        case .genre, .language, .mood:
            hub.nav.select(.search)
            hub.searchModel.query = seed.name
            hub.searchModel.submit()
        }
    }
}
