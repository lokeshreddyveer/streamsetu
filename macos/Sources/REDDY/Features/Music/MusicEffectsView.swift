import SwiftUI

// The tune button and its popover: presets, tempo, pitch and reverb. Every slider applies when it is released and nothing waits for Done.
// Tempo, pitch and reverb are global to the player and last for the session only; only saved presets are written to disk.

enum MusicEffectsLogic {
    /// Heights (0...1) of the nine bars that draw a room's tail: 9 bars over 3.6 seconds, higher for a longer decay.
    static func tailBars(decay: Double) -> [Double] {
        (0..<9).map { i in
            let t = (Double(i) + 0.5) * 0.4
            return max(0.08, min(1, exp(-6.9 * t / max(0.1, decay))))
        }
    }

    /// The song length shown under the tempo slider when tempo is not 1.
    static func songLength(duration: TimeInterval, tempo: Double) -> String? {
        guard duration > 0, abs(tempo - 1) > 0.001 else { return nil }
        return MusicTime.clock(MusicVolumeCurve.listening(duration, tempo: tempo))
    }

    static func kHz(_ hz: Double) -> String { String(format: "%.1f kHz", hz / 1000) }
}

/// The bar's tune button. It lights up whenever tempo, pitch or reverb is set, and shows the tempo when it is not normal.
struct MusicEffectsButton: View {
    let hub: MusicHub
    @State private var open = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let e = hub.player.effects
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(e.isActive || hub.player.equalizer.enabled ? accent : ColorTokens.textSecondary)
                if e.speed != 1 { Text(verbatim: MusicEffectSettings.speedLabel(e.speed)).font(Typography.timestamp).foregroundStyle(accent) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(e.isActive ? "Playback effects, on" : "Playback effects")
        .help("Tempo, pitch and reverb")
        .popover(isPresented: $open, arrowEdge: .top) { MusicEffectsPopover(hub: hub) { open = false } }.musicFocusGuard(isPresented: $open).atlas("control.music.effectsTempoPitchAndReverb")
    }
}

struct MusicEffectsPopover: View {
    let hub: MusicHub
    var onDone: () -> Void = {}
    @State private var tempoDraft: Double?
    @State private var pitchDraft: Double?
    @State private var amountDraft: Double?
    @State private var drafts: [String: Double] = [:]
    @State private var errorText: String?
    @State private var naming = false
    @State private var name = ""
    @State private var confirmReplace = false
    @State private var saveNote: String?
    @State private var showEqualizer = false
    @Environment(\.reddyAccent) private var accent

    private var player: MusicPlayer { hub.player }
    private var store: MusicEffectPresetStore { player.effectPresets }
    private var fx: MusicEffectSettings { player.effects }
    private var inRoom: Bool { player.inRoom }

    var body: some View {
        if showEqualizer {
            MusicEqualizerView(hub: hub) { showEqualizer = false }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    presets
                    adjust
                    footer
                }
                .padding(18)
            }
            .frame(width: 400, height: 560)
        }
    }

    // MARK: presets

    private var presets: some View {
        let active = MusicEffectPresets.activeChip(for: fx, saved: store.presets)
        return VStack(alignment: .leading, spacing: 8) {
            label("Presets")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(MusicEffectPresets.builtIn) { b in
                    chip(b.title, on: active == b.id, help: b.detail) { apply { $0 = inRoom ? b.settings.inRoom() : b.settings } }
                }
                ForEach(store.presets) { p in
                    chip(p.name, on: active == "saved:" + p.id, help: p.summary) { apply { $0 = MusicEffectPresetStore.settings(for: p, inRoom: inRoom) } }
                        .overlay(alignment: .topTrailing) {
                            Button { store.delete(p) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(ColorTokens.textTertiary) }
                                .buttonStyle(.plain).padding(3).accessibilityLabel("Delete preset \(p.name)").atlas("control.music.effectsDeletePreset")
                        }
                }
                Button { naming = true; saveNote = nil } label: {
                    Text("Save current sound").font(Typography.caption).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ColorTokens.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain).disabled(!store.canSave).accessibilityLabel("Save the current sound as a preset").atlas("control.music.effectsSaveTheCurrentSoundAsA")
            }
            if let e = store.loadError { Text(verbatim: e).font(Typography.caption).foregroundStyle(ColorTokens.danger) }
            if inRoom { Text("In a room a saved preset keeps its own tempo; the room plays at normal tempo.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            if naming { namingForm }
            if let n = saveNote { Text(verbatim: n).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
        }
    }

    private var namingForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder).onChange(of: name) { _, v in if v.count > MusicEffectPresets.maxNameLength { name = String(v.prefix(MusicEffectPresets.maxNameLength)) } }
                .accessibilityLabel("Preset name")
            if store.nameExists(name) { Text("A preset with this name exists. Saving replaces it.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            HStack {
                Button(store.nameExists(name) ? "Replace" : "Save") { save(replace: store.nameExists(name)) }
                    .disabled(MusicEffectPresets.cleanName(name) == nil).accessibilityLabel("Save preset").atlas("control.music.effectsSavePreset")
                Button("Cancel") { naming = false; name = "" }.atlas("control.music.effectsCancel")
            }
        }
    }

    private func save(replace: Bool) {
        let storedTempo = inRoom ? max(0.5, tempoDraft ?? fx.speed) : nil
        switch store.save(name: name, settings: fx, storedTempo: storedTempo, replace: replace) {
        case .saved, .replaced: naming = false; name = ""; saveNote = "Saved."
        case .needsReplace: saveNote = "A preset with this name exists."
        case .nothingToSave: saveNote = "This sound is already a preset. Nothing to save."
        case .invalidName: saveNote = "Give the preset a name of up to 80 characters."
        case .unavailable: saveNote = "Saving is turned off because the saved presets could not be read."
        }
    }

    private func chip(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(Typography.captionMedium).lineLimit(1).frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(on ? Color.white : ColorTokens.textPrimary)
                .background(on ? accent : ColorTokens.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel("Preset \(title)").accessibilityAddTraits(on ? .isSelected : []).atlas("control.music.effectsPreset")
    }

    // MARK: adjust

    private var adjust: some View {
        VStack(alignment: .leading, spacing: 16) {
            label("Adjust")
            tempoRow
            pitchRow
            reverbBlock
            if let e = errorText { Text(verbatim: e).font(Typography.caption).foregroundStyle(ColorTokens.danger) }
            if let n = player.effectsNotice { Text(verbatim: n).font(Typography.caption).foregroundStyle(ColorTokens.danger) }
        }
    }

    private var tempoRow: some View {
        let v = tempoDraft ?? fx.speed
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tempo").font(Typography.bodyMedium)
                Button("Reset") { apply { $0.speed = 1 } }.buttonStyle(.plain).font(Typography.caption).foregroundStyle(accent)
                    .opacity(fx.speed == 1 ? 0 : 1).disabled(fx.speed == 1 || inRoom).accessibilityLabel("Reset tempo").atlas("control.music.effectsResetTempo")
                Spacer()
                Text(verbatim: MusicEffectSettings.speedLabel(v)).font(Typography.timestamp)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(ColorTokens.elevated.opacity(0.7), in: Capsule())
            }
            Slider(value: Binding(get: { v }, set: { tempoDraft = MusicEffectSettings.snappedSpeed($0) }), in: MusicEffectSettings.speedRange,
                   step: MusicEffectSettings.speedStep) { editing in
                if !editing, let d = tempoDraft { apply { $0.speed = d }; tempoDraft = nil }
            }
            .disabled(inRoom).accessibilityLabel("Tempo")
            HStack {
                Text("slower"); Spacer(); Text("Normal"); Spacer(); Text("faster")
            }.font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
            if inRoom { Text("Tempo is locked while you are in a room.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            else if let len = MusicEffectsLogic.songLength(duration: player.duration, tempo: fx.speed) {
                Text(verbatim: "Song length at this tempo: \(len)").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    private var pitchRow: some View {
        let v = pitchDraft ?? Double(fx.semitones)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pitch").font(Typography.bodyMedium)
                Button("Reset") { apply { $0.semitones = 0 } }.buttonStyle(.plain).font(Typography.caption).foregroundStyle(accent)
                    .opacity(fx.semitones == 0 ? 0 : 1).disabled(fx.semitones == 0).accessibilityLabel("Reset pitch").atlas("control.music.effectsResetPitch")
                Spacer()
                Text(verbatim: MusicEffectSettings.pitchLabel(Int(v))).font(Typography.timestamp)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(ColorTokens.elevated.opacity(0.7), in: Capsule())
            }
            Slider(value: Binding(get: { v }, set: { pitchDraft = $0.rounded() }), in: -12...12, step: 1) { editing in
                if !editing, let d = pitchDraft { apply { $0.semitones = Int(d) }; pitchDraft = nil }
            }
            .accessibilityLabel("Pitch in semitones")
        }
    }

    private var reverbBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reverb").font(Typography.bodyMedium)
                Spacer()
                Toggle("", isOn: Binding(get: { fx.reverb.enabled }, set: { on in apply { $0.reverb.enabled = on } }))
                    .labelsHidden().toggleStyle(.switch).tint(accent).accessibilityLabel("Reverb").atlas("control.music.effectsReverb")
            }
            if fx.reverb.enabled {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(MusicReverbRoom.allCases) { room in
                        let on = fx.reverb.preset == room.rawValue
                        Button { apply { $0.chooseRoom(room) } } label: {
                            VStack(spacing: 4) {
                                HStack(alignment: .bottom, spacing: 2) {
                                    ForEach(Array(MusicEffectsLogic.tailBars(decay: room.naturalDecay).enumerated()), id: \.offset) { _, h in
                                        RoundedRectangle(cornerRadius: 1).fill(on ? accent : ColorTokens.textTertiary).frame(width: 3, height: 16 * h)
                                    }
                                }.frame(height: 16, alignment: .bottom)
                                Text(verbatim: room.title).font(Typography.micro).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? accent.opacity(0.18) : ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel(room.title).accessibilityAddTraits(on ? .isSelected : []).atlas("control.music.effectsMusiceffectspopoverreverbblockButton")
                    }
                }
                slider("Amount", key: "wet", value: fx.reverb.wet, range: 0...100, step: 1, text: { "\(Int($0)) %" }) { $0.reverb.wet = $1 }
                DisclosureGroup("Fine tune") {
                    VStack(spacing: 10) {
                        slider("Dry", key: "dry", value: fx.reverb.dry, range: 0...100, step: 1, text: { "\(Int($0)) %" }) { $0.reverb.dry = $1 }
                        slider("Decay", key: "decay", value: fx.reverb.decay, range: 0.1...10, step: 0.1, text: { String(format: "%.1f s", $0) }) { $0.reverb.decay = $1 }
                        slider("Pre-delay", key: "pre", value: fx.reverb.preDelay, range: 0...200, step: 1, text: { "\(Int($0)) ms" }) { $0.reverb.preDelay = $1 }
                        slider("Damping", key: "damp", value: fx.reverb.damping, range: 500...20_000, step: 100, text: { MusicEffectsLogic.kHz($0) }) { $0.reverb.damping = $1 }
                        slider("Reflections", key: "refl", value: fx.reverb.reflections, range: 0...100, step: 1, text: { "\(Int($0)) %" }) { $0.reverb.reflections = $1 }
                    }.padding(.top, 6)
                }
                .font(Typography.caption)
            }
        }
    }

    private func slider(_ title: String, key: String, value: Double, range: ClosedRange<Double>, step: Double,
                        text: (Double) -> String, set: @escaping (inout MusicEffectSettings, Double) -> Void) -> some View {
        let v = drafts[key] ?? value
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(verbatim: title).font(Typography.caption); Spacer(); Text(verbatim: text(v)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary) }
            Slider(value: Binding(get: { v }, set: { drafts[key] = $0 }), in: range, step: step) { editing in
                if !editing, let d = drafts[key] { apply { set(&$0, d) }; drafts[key] = nil }
            }
            .accessibilityLabel(title)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button { showEqualizer = true } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
                .accessibilityLabel(player.equalizer.enabled ? "Equalizer, on" : "Equalizer").help("Seven bands, a tone pad and presets").atlas("control.music.effectsEqualizer")
            Button("Reset all") { apply { $0 = inRoom ? MusicEffectSettings.original.inRoom() : .original } }
                .disabled(fx.isOriginal).accessibilityLabel("Reset all effects").atlas("control.music.effectsResetAllEffects")
            Spacer()
            Button("Done") { onDone() }.keyboardShortcut(.defaultAction).accessibilityLabel("Done").atlas("control.music.effectsDone")
        }
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
    }

    /// Applies one change as a unit. A refused change leaves the confirmed values in place, resets every slider draft and shows the reason.
    private func apply(_ change: (inout MusicEffectSettings) -> Void) {
        var s = fx
        change(&s)
        do { try player.setEffects(s); errorText = nil }
        catch { errorText = error.localizedDescription }
        tempoDraft = nil; pitchDraft = nil; drafts = [:]
    }
}
