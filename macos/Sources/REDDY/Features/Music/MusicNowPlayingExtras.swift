import SwiftUI

// Small pieces of the Now Playing tab: the line that says where the music is playing from with a peek at the next song, and the audio settings popover
// (loudness, crossfade, tempo, pitch and reverb, the equalizer, the output and the stream's signal information) that the "..." menu opens.

/// Under the controls: "Playing from <album or playlist>" and the next song in the queue. A press on the next song opens the Queue tab.
/// It reads the queue here and nowhere above it, so a song change redraws this view and not the whole tab.
struct MusicNowPlayingContext: View {
    let hub: MusicHub
    var panelState: MusicContextPanelState
    @Environment(\.reddyAccent) private var accent
    private var player: MusicPlayer { hub.player }

    var body: some View {
        let rows = player.rows
        let next: MusicQueue.Entry? = player.index.flatMap { $0 + 1 < rows.count ? rows[$0 + 1] : nil }
        VStack(spacing: MusicSpace.xs) {
            if let s = MusicPlayingFrom.line(source: player.sourceName, providerNames: hub.registry.all.map { $0.info.name }) {
                Text(verbatim: Localized.string("Playing from %@", s)).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let n = next { upNext(n) }
        }
    }

    private func upNext(_ e: MusicQueue.Entry) -> some View {
        Button { panelState.showPanel(.queue) } label: {
            HStack(spacing: MusicSpace.xs) {
                MusicArtwork(track: e.track, size: 32, corner: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Up next").font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
                    Text(verbatim: e.track.title).font(Typography.captionMedium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    Text(verbatim: e.track.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            .padding(MusicSpace.xs).contentShape(Rectangle())
            .background(ColorTokens.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.string("Up next: %@. Open the queue", e.track.title))
        .musicTooltip("Open the queue").atlas("control.music.nowPlayingUpNext")
    }
}

/// The audio settings: loudness, crossfade, then the tempo, pitch and reverb page, the equalizer page and the signal information page, with the output and the
/// sleep timer at hand. Everything here changes the one player; nothing is kept in a copy.
struct MusicAudioSettingsPopover: View {
    let hub: MusicHub
    private enum Page { case main, effects, equalizer, signal }
    @State private var page = Page.main
    @Environment(\.reddyAccent) private var accent

    private var player: MusicPlayer { hub.player }
    private var settings: MusicSettings { hub.library.settings }

    var body: some View {
        switch page {
        case .main: main
        case .effects: MusicEffectsPopover(hub: hub) { page = .main }
        case .equalizer: MusicEqualizerView(hub: hub) { page = .main }
        case .signal: signal
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text("Audio settings").font(MusicTypeRole.section.font)
            Toggle("Normalise volume", isOn: Binding(get: { settings.normalizeVolume }, set: { hub.library.settings.normalizeVolume = $0; player.refreshNormalisation() }))
                .toggleStyle(.switch).tint(accent).atlas("control.music.audioNormalize")
            HStack {
                Text("Crossfade").font(Typography.body)
                Spacer(minLength: MusicSpace.sm)
                Picker("Crossfade", selection: crossfade) {
                    ForEach(0...10, id: \.self) { n in Text(verbatim: n == 0 ? Localized.string("Off") : Localized.string("%d s", n)).tag(n) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().atlas("control.music.audioCrossfade")
            }
            Divider()
            Button { page = .effects } label: { pageLabel("Tempo, pitch and reverb", symbol: "slider.horizontal.3") }
                .buttonStyle(.plain).accessibilityLabel(Localized.string("Tempo, pitch and reverb")).atlas("control.music.audioEffectsOpen")
            Button { page = .equalizer } label: { pageLabel("Equalizer", symbol: "slider.vertical.3") }
                .buttonStyle(.plain).accessibilityLabel(Localized.string("Equalizer")).atlas("control.music.audioEqualizerOpen")
            Button { page = .signal } label: { pageLabel("Signal information", symbol: "waveform") }
                .buttonStyle(.plain).accessibilityLabel(Localized.string("Signal information")).atlas("control.music.audioSignalOpen")
            Divider()
            HStack {
                Text("Output").font(Typography.body)
                Spacer(minLength: MusicSpace.sm)
                MusicOutputControl(hub: hub)
            }
            Menu {
                MusicSleepItems(hub: hub)
            } label: {
                Label(sleepTitle, systemImage: "moon.zzz").font(Typography.body)
            }
            .menuStyle(.borderlessButton).fixedSize().atlas("control.music.playerAndQueueSleepTimer")
        }
        .padding(MusicSpace.md).frame(width: 300)
        .musicDialogAccessibility(Localized.string("Audio settings"))
    }

    private var sleepTitle: String {
        if let left = hub.sleepTimer.remaining { return Localized.string("Sleep timer, %@ left", MusicSleepLogic.label(remaining: left)) }
        return Localized.string("Sleep Timer")
    }

    private var crossfade: Binding<Int> {
        Binding(get: { Int(MusicCrossfade.length(setting: hub.library.settings.crossfadeSeconds)) },
                set: { n in
                    if n > 0 { hub.library.settings.player.crossfadeLength = n }
                    hub.library.settings.crossfadeSeconds = Double(n)
                })
    }

    private func pageLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: symbol).font(MusicTokens.iconSmall).frame(width: 20).foregroundStyle(ColorTokens.textSecondary)
            Text(LocalizedStringKey(title)).font(Typography.body).foregroundStyle(ColorTokens.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
        }
        .contentShape(Rectangle())
    }

    /// What the stream reports, and nothing else.
    private var signal: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Button { page = .main } label: { Label("Audio settings", systemImage: "chevron.left").font(Typography.captionMedium) }
                .buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.audioBack")
            MusicQualityPopover(facts: MusicQualityFacts.make(stream: player.currentStream, effectsActive: player.effects.isActive || player.equalizer.enabled, route: routeName))
        }
        .padding(.top, MusicSpace.md).padding(.leading, MusicSpace.md)
    }

    private var routeName: String? {
        #if os(macOS)
        let o = player.outputs
        return MusicOutputRoute.label(resolution: o.resolution, chosenName: o.chosenName)
        #else
        return nil
        #endif
    }
}
