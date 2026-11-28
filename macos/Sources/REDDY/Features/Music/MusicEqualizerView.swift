import SwiftUI
import UniformTypeIdentifiers

// The equalizer: seven sliders, a bass and treble pad, sixteen presets and stereo widening. It opens from the effects popover in the
// player bar and from the Playback settings. Changes apply to the sound as they are made and are saved with the player preferences.

enum MusicEqualizerLogic {
    static func gainLabel(_ db: Double) -> String { abs(db) < 0.05 ? "0 dB" : String(format: "%+.1f dB", db) }

    static func bandLabel(_ hz: Double) -> String { hz >= 1_000 ? String(format: hz.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0fk" : "%.1fk", hz / 1_000) : String(format: "%.0f", hz) }

    /// Pad position (0...1 across and down, origin top-left) to bass and treble values (-1...1). Up is more treble, right is more bass.
    static func padValues(x: Double, y: Double) -> (bass: Double, treble: Double) {
        (min(1, max(-1, x * 2 - 1)), min(1, max(-1, 1 - y * 2)))
    }

    static func padPosition(bass: Double, treble: Double) -> (x: Double, y: Double) { ((bass + 1) / 2, (1 - treble) / 2) }
}

struct MusicEqualizerView: View {
    let hub: MusicHub
    var onBack: (() -> Void)?
    @State private var draft: MusicEqualizerSettings?
    @State private var errorText: String?
    @State private var importing = false
    @State private var importNote: String?
    @Environment(\.reddyAccent) private var accent

    private var player: MusicPlayer { hub.player }
    private var eq: MusicEqualizerSettings { draft ?? player.equalizer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let e = errorText { Text(verbatim: e).font(Typography.caption).foregroundStyle(ColorTokens.danger) }
                presetRow
                preampAndImport
                sliders
                padSection
                widening
                MusicEqualizerExtras(eq: eq, commit: { change in commit(change) })
                Text("The equalizer plays through the audio effects engine, so crossfade and gapless playback are off while it is on.")
                    .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            .padding(18)
        }
        .frame(width: 400, height: 560)
        .opacity(eq.enabled ? 1 : 0.92)
    }

    // MARK: header and presets

    private var header: some View {
        HStack {
            if let onBack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("Back to effects").atlas("control.music.equalizerBackToEffects")
            }
            Text("Equalizer").font(Typography.bodyMedium)
            Spacer()
            Button("Reset") { commit { $0.reset() } }.buttonStyle(.plain).font(Typography.caption).foregroundStyle(accent)
                .disabled(eq == MusicEqualizerSettings()).accessibilityLabel("Reset the equalizer").atlas("control.music.equalizerResetTheEqualizer")
            Toggle("", isOn: Binding(get: { eq.enabled }, set: { on in commit { $0.enabled = on } }))
                .labelsHidden().toggleStyle(.switch).tint(accent).accessibilityLabel("Equalizer").atlas("control.music.equalizerEqualizer")
        }
    }

    private var presetRow: some View {
        let current = MusicEqualizerPresets.matching(eq.bands)
        return HStack {
            Text("Preset").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Spacer()
            Picker("Preset", selection: Binding(get: { current?.id ?? "custom" }, set: { id in
                if let p = MusicEqualizerPresets.preset(id: id) { commit { $0.apply(p) } }
            })) {
                if current == nil { Text("Custom").tag("custom") }
                ForEach(MusicEqualizerPresets.all) { p in Text(verbatim: p.title).tag(p.id) }
            }
            .labelsHidden().frame(width: 190).accessibilityLabel("Equalizer preset").atlas("control.music.equalizerEqualizerPreset")
        }
    }

    // MARK: preamp and import

    private var preampAndImport: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Automatic preamp").font(Typography.bodyMedium)
                Spacer()
                Text(verbatim: MusicEqualizerLogic.gainLabel(MusicEqualizerMath.makeupGainDB(eq))).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary)
                Toggle("", isOn: Binding(get: { eq.autoPreamp }, set: { on in commit { $0.autoPreamp = on } }))
                    .labelsHidden().toggleStyle(.switch).tint(accent).accessibilityLabel("Automatic preamp").atlas("control.music.equalizerAutomaticPreamp")
            }
            Text("Lowers the whole curve by its highest boost, so boosts never clip.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            HStack {
                Button("Import preset file…") { importing = true }.font(Typography.caption).accessibilityLabel("Import an equalizer preset file").atlas("control.music.equalizerImportAnEqualizerPresetFile")
                Spacer()
            }
            if let n = importNote { Text(verbatim: n).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in importFile(result) }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try MusicEqualizerImport.load(url)
            commit { $0.bands = r.bands; $0.padBass = 0; $0.padTreble = 0; $0.enabled = true }
            importNote = r.approximated
                ? Localized.string("Imported %d filters. Fitted to the seven bands, so the curve is approximate.", r.filterCount)
                : Localized.string("Imported %d filters.", r.filterCount)
            if !r.skippedLines.isEmpty { importNote = (importNote ?? "") + " " + Localized.string("%d lines were skipped.", r.skippedLines.count) }
        } catch MusicEqualizerImport.Failure.tooLarge {
            importNote = Localized.string("That file is too large to be a preset.")
        } catch {
            importNote = Localized.string("No usable filters were found in that file.")
        }
    }

    // MARK: sliders

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Bands")
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(MusicEqualizerMath.bandCentres.enumerated()), id: \.offset) { i, hz in
                    VStack(spacing: 6) {
                        Text(verbatim: String(format: "%+.0f", eq.bands[i])).font(Typography.micro).foregroundStyle(ColorTokens.textSecondary).frame(height: 12)
                        Slider(value: Binding(get: { eq.bands[i] }, set: { v in
                            var d = eq; d.bands[i] = (v * 2).rounded() / 2; d.enabled = true; draft = d
                        }), in: MusicEqualizerSettings.gainRange) { editing in
                            if !editing, let d = draft { draft = nil; commit { $0 = d } }
                        }
                        .rotationEffect(.degrees(-90)).frame(width: 110, height: 24).frame(width: 30, height: 110)
                        .accessibilityLabel("\(MusicEqualizerLogic.bandLabel(hz)) hertz band").accessibilityValue(MusicEqualizerLogic.gainLabel(eq.bands[i]))
                        Text(verbatim: MusicEqualizerLogic.bandLabel(hz)).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: tone pad

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Tone pad")
            HStack(alignment: .center, spacing: 14) {
                GeometryReader { geo in
                    let pos = MusicEqualizerLogic.padPosition(bass: eq.padBass, treble: eq.padTreble)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ColorTokens.elevated.opacity(0.6))
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                            p.move(to: CGPoint(x: 0, y: geo.size.height / 2)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                        }.stroke(ColorTokens.line, lineWidth: 1)
                        Circle().fill(accent).frame(width: 18, height: 18)
                            .position(x: pos.x * geo.size.width, y: pos.y * geo.size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let v = MusicEqualizerLogic.padValues(x: g.location.x / max(1, geo.size.width), y: g.location.y / max(1, geo.size.height))
                            var d = eq; d.padBass = (v.bass * 10).rounded() / 10; d.padTreble = (v.treble * 10).rounded() / 10; d.enabled = true; draft = d
                        }
                        .onEnded { _ in if let d = draft { draft = nil; commit { $0 = d } } })
                    .accessibilityElement()
                    .accessibilityLabel("Bass and treble pad")
                    .accessibilityValue("Bass \(MusicEqualizerLogic.gainLabel(eq.padBass * MusicEqualizerMath.padDB)), treble \(MusicEqualizerLogic.gainLabel(eq.padTreble * MusicEqualizerMath.padDB))")
                    .accessibilityAdjustableAction { dir in
                        commit { $0.padBass = min(1, max(-1, $0.padBass + (dir == .increment ? 0.1 : -0.1))); $0.enabled = true }
                    }
                }
                .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Bass  \(MusicEqualizerLogic.gainLabel(eq.padBass * MusicEqualizerMath.padDB))").font(Typography.timestamp)
                    Text(verbatim: "Treble  \(MusicEqualizerLogic.gainLabel(eq.padTreble * MusicEqualizerMath.padDB))").font(Typography.timestamp)
                    Text("Right adds bass, up adds treble.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    Button("Centre") { commit { $0.padBass = 0; $0.padTreble = 0 } }.font(Typography.caption)
                        .disabled(eq.padBass == 0 && eq.padTreble == 0).accessibilityLabel("Centre the tone pad").atlas("control.music.equalizerCentreTheTonePad")
                }
            }
        }
    }

    // MARK: widening

    private var widening: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stereo widening").font(Typography.bodyMedium)
                Spacer()
                Toggle("", isOn: Binding(get: { eq.spatial.enabled }, set: { on in commit { $0.spatial.enabled = on } }))
                    .labelsHidden().toggleStyle(.switch).tint(accent).accessibilityLabel("Stereo widening").atlas("control.music.equalizerStereoWidening")
            }
            if eq.spatial.enabled {
                HStack {
                    Text("Amount").font(Typography.caption)
                    Slider(value: Binding(get: { eq.spatial.amount }, set: { v in var d = eq; d.spatial.amount = v; draft = d }), in: 0...1) { editing in
                        if !editing, let d = draft { draft = nil; commit { $0 = d } }
                    }.accessibilityLabel("Widening amount")
                    Text(verbatim: "\(Int((eq.spatial.amount * 100).rounded())) %").font(Typography.timestamp).frame(width: 44, alignment: .trailing)
                }
                Text("Makes stereo music feel wider. It is not surround sound, and mono songs do not change.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
    }

    /// Applies one change as a unit. A refused change leaves the confirmed values in place and shows the reason.
    private func commit(_ change: (inout MusicEqualizerSettings) -> Void) {
        var s = eq
        change(&s)
        do { try player.setEqualizer(s); errorText = nil } catch { errorText = error.localizedDescription }
        draft = nil
    }
}
