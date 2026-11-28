import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Theme choices for Music: follow the cover (the existing switch), or a Material You palette seeded from the cover, a picked colour or the system accent.
// macOS has no wallpaper palette API, so those three are the portable options. Everything is off or standard until the person changes it.

private struct MusicMaterialThemeModifier: ViewModifier {
    let url: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.reddyAccent) private var base
    @AppStorage(MusicThemeSettings.paletteKey) private var paletteRaw = MusicPaletteChoice.standard.rawValue
    @AppStorage(MusicThemeSettings.pickedColorKey) private var pickedHex = MusicThemeSettings.defaultPicked
    @State private var cover: MusicRGB?
    @State private var system: MusicRGB?

    private var choice: MusicPaletteChoice { MusicPaletteChoice(rawValue: paletteRaw) ?? .standard }
    private var resolved: MusicMaterialScheme? {
        let picked = MusicOKLCH.rgb(hex: pickedHex) ?? MusicThemeSettings.pickedColor()
        guard let seed = MusicThemeSettings.seedColor(for: choice, cover: cover, picked: picked, system: system) else { return nil }
        return MusicMaterialPalette.scheme(MusicMaterialSeed(seed), dark: scheme == .dark)
    }

    func body(content: Content) -> some View {
        let s = resolved
        content
            .environment(\.reddyAccent, s.map { Color($0.primary) } ?? base)
            .environment(\.musicTint, s?.tintFills)
            .task(id: choice == .materialCover ? url : nil) {
                guard choice == .materialCover, let url else { cover = nil; return }
                cover = nil
                cover = await MusicAdaptiveColorCache.shared.rawColor(for: url)
            }
            .task(id: choice) { if choice == .materialSystem { system = MusicSystemAccent.current() } }
    }
}

extension View {
    /// Inside Music only: when the person chose a Material You palette, its primary becomes the accent and its surfaces tint the fills. Apply it outside
    /// `musicAdaptiveAccent` so a Material choice wins over the plain cover accent; on "Standard" it changes nothing.
    func musicMaterialTheme(for thumbs: [MusicThumbnail]) -> some View {
        modifier(MusicMaterialThemeModifier(url: thumbs.best(minSide: 120)))
    }
}

/// The Appearance group of the Music settings: adapt colours to artwork, palette choice, picked colour and the light around music videos.
struct MusicThemeSettingsSection: View {
    let hub: MusicHub
    @AppStorage(MusicAdaptiveSettings.defaultsKey) private var adaptive = false
    @AppStorage(MusicThemeSettings.paletteKey) private var paletteRaw = MusicPaletteChoice.standard.rawValue
    @AppStorage(MusicThemeSettings.pickedColorKey) private var pickedHex = MusicThemeSettings.defaultPicked
    @AppStorage(MusicThemeSettings.ambientLightKey) private var ambient = false
    @AppStorage(MusicTextStep.defaultsKey) private var textStepRaw = MusicTextStep.standard.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.self) private var environment

    private var choice: MusicPaletteChoice { MusicPaletteChoice(rawValue: paletteRaw) ?? .standard }

    var body: some View {
        MusicSettingsGroup(title: "Appearance") {
            MusicToggleRow(title: "Adapt colours to artwork", info: "Music takes its colours from the song that is playing. Nothing changes until you switch it on.", isOn: $adaptive)
            MusicPickerRow(title: "Palette", info: "A Material You palette is used instead of the plain cover accent while it is on.",
                           selection: Binding(get: { choice }, set: { paletteRaw = $0.rawValue }),
                           options: MusicPaletteChoice.allCases.map { ($0, $0.title) })
            if choice == .materialPicked {
                MusicSettingsRow(title: "Seed colour") {
                    ColorPicker("Seed colour", selection: Binding(get: { Color(MusicOKLCH.rgb(hex: pickedHex) ?? MusicRGB(0.4, 0.31, 0.64)) }, set: { setPicked($0) }), supportsOpacity: false)
                }
            }
            if choice != .standard { MusicSettingsRow(title: "Preview") { swatches } }
            MusicPickerRow(title: "Text size", info: "Changes the size of text across Music. Rows grow to fit.",
                           selection: Binding(get: { MusicTextStep(raw: textStepRaw) }, set: { textStepRaw = $0.rawValue }),
                           options: MusicTextStep.allCases.map { ($0, $0.label) })
            MusicSettingsDisclosure(title: "More options") {
                MusicToggleRow(title: "Light around music videos", info: "Soft light around the picture, taken from the video. It updates a few times a second while the video plays and stays still when paused.", isOn: $ambient)
                MusicSettingsRow(title: "Reduce motion", detail: "Follows System Settings, Accessibility, Display.") {
                    Text("Follows system").musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }
        }
    }

    private var seedColor: MusicRGB? {
        switch choice {
        case .standard: nil
        case .materialPicked: MusicOKLCH.rgb(hex: pickedHex)
        case .materialSystem: MusicSystemAccent.current()
        case .materialCover: nil
        }
    }

    /// A small preview of the roles the palette produces. For the cover choice the seed depends on the song, so the baseline is shown.
    private var swatches: some View {
        let s = MusicMaterialPalette.scheme(seedColor.map(MusicMaterialSeed.init) ?? .baseline, dark: scheme == .dark)
        return HStack(spacing: Spacing.xs) {
            ForEach([s.primary, s.primaryContainer, s.secondaryContainer, s.surfaceContainerHigh, s.background], id: \.self) { c in
                RoundedRectangle(cornerRadius: MusicTokens.radiusRow / 2, style: .continuous).fill(Color(c)).frame(width: Spacing.xl, height: Spacing.xl)
                    .overlay(RoundedRectangle(cornerRadius: MusicTokens.radiusRow / 2, style: .continuous).strokeBorder(ColorTokens.line))
            }
        }
        .accessibilityHidden(true)
    }

    private func setPicked(_ color: Color) {
        let r = color.resolve(in: environment)
        pickedHex = MusicOKLCH.hex(MusicRGB(Double(r.red), Double(r.green), Double(r.blue)))
    }
}
