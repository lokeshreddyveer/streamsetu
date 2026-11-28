import SwiftUI

// The row of lyric controls under the lyrics: timing offset with nudge buttons, the reading (romanisation) switch, the translation switch with an
// on-device state, text size, and sharing lines.

enum MusicLyricsToolbarLogic {
    /// What the translation control shows.
    enum TranslationControl: Equatable {
        /// Some lines already carry a translation from the source: a plain switch.
        case sourceProvided
        /// Nothing from the source; the device can translate.
        case translateOnDevice
        case translating(String)
        case ready(String)
        case message(String)
        /// No on-device translator on this system.
        case unavailable

        var title: String {
            switch self {
            case .sourceProvided: Localized.string("Translation")
            case .translateOnDevice: Localized.string("Translate on this device")
            case .translating(let l): Localized.string("Translating to %@...", l)
            case .ready(let l): Localized.string("Translated to %@", l)
            case .message(let m): Localized.string(m)
            case .unavailable: Localized.string("Translation is not available on this Mac")
            }
        }
    }

    static func translationControl(hasSourceTranslation: Bool, deviceAvailable: Bool, state: MusicLyricsTranslationState, languageName: String) -> TranslationControl {
        if hasSourceTranslation { return .sourceProvided }
        guard deviceAvailable else { return .unavailable }
        switch state {
        case .idle: return .translateOnDevice
        case .loading: return .translating(languageName)
        case .ready: return .ready(languageName)
        case .unchanged: return .message(Localized.string("These lyrics are already in %@", languageName))
        case .unavailable(let m): return .message(m)
        }
    }

    static func nudged(_ current: Int64, by delta: Int64) -> Int64 { MusicLyricsMotion.clampUIOffset(current + delta) }
}

struct MusicLyricsToolbar: View {
    let hub: MusicHub
    let track: MusicTrack
    let lyrics: MusicLyrics
    let translation: MusicLyricsTranslationService
    let languageName: String
    let onOffsetChanged: (Int64) -> Void
    let onTranslate: () -> Void
    let onShare: () -> Void
    @AppStorage(MusicLyricsPrefs.textStepKey) private var textStep = 1
    @AppStorage(MusicLyricsPrefs.alignmentKey) private var alignRaw = 0
    @Environment(\.reddyAccent) private var accent

    private var settings: MusicSettings { hub.library.settings }

    private var alignButton: some View {
        let a = MusicLyricsAlignment(rawValue: alignRaw) ?? .automatic
        return Button { alignRaw = a.next.rawValue } label: { Image(systemName: a.symbol) }
            .accessibilityLabel(Localized.string(a.title)).musicTooltip(verbatim: Localized.string(a.title)).atlas("control.music.lyricsAlignment")
    }

    var body: some View {
        let control = MusicLyricsToolbarLogic.translationControl(hasSourceTranslation: lyrics.hasTranslation, deviceAvailable: translation.isAvailable,
                                                                state: translation.translation, languageName: languageName)
        ScrollView(.horizontal) {
        HStack(spacing: 12) {
            if lyrics.isSynced { offsetControl }
            if lyrics.hasRomanization || lyrics.isSynced {
                toggle("character.book.closed", "Romanisation", on: settings.showRomanisation) { hub.library.settings.showRomanisation.toggle() }
            }
            if lyrics.isSynced { translationControl(control) }
            Spacer(minLength: 0)
            alignButton
            Button { textStep = max(0, textStep - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .disabled(textStep == 0).accessibilityLabel("Smaller lyrics text").atlas("control.music.lyricsSmallerLyricsText")
            Button { textStep = min(MusicLyricsPrefs.textSteps.count - 1, textStep + 1) } label: { Image(systemName: "textformat.size.larger") }
                .disabled(textStep == MusicLyricsPrefs.textSteps.count - 1).accessibilityLabel("Larger lyrics text").atlas("control.music.lyricsLargerLyricsText")
            if lyrics.isSynced {   // picking lines needs timed lines; plain lyrics have no picker, so no dead button
                Button(action: onShare) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Pick lines to share").atlas("control.music.lyricsPickLinesToShare")
            }
        }
        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.plain).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
        .scrollIndicators(.hidden)
    }

    private func toggle(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(Localized.string(label), systemImage: symbol).foregroundStyle(on ? accent : ColorTokens.textSecondary)
        }
        .accessibilityLabel(Localized.string(label)).accessibilityValue(Localized.string(on ? "On" : "Off")).atlas("control.music.lyricsMusiclyricstoolbartoggleButton")
    }

    private var offsetControl: some View {
        HStack(spacing: 6) {
            Button { nudge(-MusicLyricsMotion.offsetStepMs) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Show lyrics earlier").atlas("control.music.lyricsShowLyricsEarlier")
            Text(verbatim: MusicLyricsMotion.offsetLabel(lyrics.offsetMs)).font(Typography.timestamp).frame(minWidth: 46)
                .accessibilityLabel(Localized.string("Lyrics offset %@", MusicLyricsMotion.offsetLabel(lyrics.offsetMs)))
            Button { nudge(MusicLyricsMotion.offsetStepMs) } label: { Image(systemName: "plus.circle") }.accessibilityLabel("Show lyrics later").atlas("control.music.lyricsShowLyricsLater")
            if lyrics.offsetMs != 0 { Button("Reset") { set(0) }.accessibilityLabel("Reset the lyrics offset").atlas("control.music.lyricsResetTheLyricsOffset") }
        }
        .help("Lyrics ahead of the singer? Move them later.")
    }

    private func nudge(_ d: Int64) { set(MusicLyricsToolbarLogic.nudged(lyrics.offsetMs, by: d)) }

    private func set(_ ms: Int64) {
        hub.lyrics.setOffset(ms, for: track)
        onOffsetChanged(ms)
    }

    @ViewBuilder
    private func translationControl(_ c: MusicLyricsToolbarLogic.TranslationControl) -> some View {
        switch c {
        case .sourceProvided:
            toggle("translate", "Translation", on: settings.showTranslation) { hub.library.settings.showTranslation.toggle() }
        case .translateOnDevice:
            Button(action: onTranslate) { Label(c.title, systemImage: "translate") }.accessibilityLabel("Translate the lyrics on this device").atlas("control.music.lyricsTranslateTheLyricsOnThisDevice")
        case .translating:
            HStack(spacing: 4) { MusicLoadingIcon(size: MusicIconSize.tiny); Text(verbatim: c.title) }
        case .ready:
            toggle("translate", c.title, on: settings.showTranslation) { hub.library.settings.showTranslation.toggle() }
        case .message, .unavailable:
            Label(c.title, systemImage: "translate").foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(c.title)
        }
    }
}
