import SwiftUI

// What sits under the seven-band equalizer: your own presets, balance and mono, bands you place by hand, and remembering the sound for each output.

struct MusicEqualizerExtras: View {
    let eq: MusicEqualizerSettings
    let commit: ((inout MusicEqualizerSettings) -> Void) -> Void
    @State private var draft: MusicEqualizerSettings?
    @State private var naming = false
    @State private var newName = ""
    @Environment(\.reddyAccent) private var accent
    private let presets = MusicCustomPresets.shared
    private let profiles = MusicDeviceAudioProfiles.shared

    private var shown: MusicEqualizerSettings { draft ?? eq }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            yourPresets
            balanceAndMono
            parametric
            perOutput
        }
        .alert("Save preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { presets.save(eq, as: newName); newName = "" }.atlas("control.music.eqPresetSaveConfirm")
            Button("Cancel", role: .cancel) { newName = "" }.atlas("control.music.eqPresetCancel")
        } message: { Text("Saves the seven bands, the tone pad and your own bands under this name.") }
    }

    // MARK: your presets

    private var yourPresets: some View {
        HStack {
            Text("Your presets").font(Typography.bodyMedium)
            Spacer()
            Menu("Choose") {
                if presets.list.isEmpty { Text("Nothing saved yet").foregroundStyle(ColorTokens.textTertiary) }
                ForEach(presets.list) { p in
                    Button(p.name) { commit { $0 = p.settings } }.atlas("control.music.eqPresetApply")
                }
                if !presets.list.isEmpty {
                    Divider()
                    Menu("Delete") { ForEach(presets.list) { p in Button(p.name, role: .destructive) { presets.delete(p.id) }.atlas("control.music.eqPresetDelete") } }.atlas("control.music.eqPresetDeleteMenu")
                }
            }.menuStyle(.button).fixedSize().atlas("control.music.eqYourPresets")
            Button("Save current…") { naming = true }.font(Typography.caption).foregroundStyle(accent).buttonStyle(.plain).atlas("control.music.eqSavePreset")
        }
    }

    // MARK: balance and mono

    private var balanceAndMono: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Balance").font(Typography.bodyMedium)
                Spacer()
                Text(verbatim: MusicEqualizerExtrasLogic.balanceLabel(shown.balance)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary)
                Button("Centre") { commit { $0.balance = 0 } }.font(Typography.caption).foregroundStyle(accent).buttonStyle(.plain)
                    .disabled(abs(shown.balance) < 0.01).atlas("control.music.eqBalanceCentre")
            }
            Slider(value: Binding(get: { shown.balance }, set: { v in var d = eq; d.balance = abs(v) < 0.04 ? 0 : v; draft = d }), in: -1...1) { editing in
                if !editing, let d = draft { draft = nil; commit { $0 = d } }
            }.accessibilityLabel("Balance").atlas("control.music.eqBalance")
            HStack {
                Text("Mono").font(Typography.bodyMedium)
                Spacer()
                Toggle("", isOn: Binding(get: { eq.mono }, set: { on in commit { $0.mono = on } })).labelsHidden().toggleStyle(.switch).tint(accent)
                    .accessibilityLabel("Mono").atlas("control.music.eqMono")
            }
            Text("Mono plays the same mix in both ears. Balance and mono work even when the equalizer is off.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    // MARK: your own bands

    private var parametric: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your own bands").font(Typography.bodyMedium)
                Spacer()
                Button("Add band") { commit { if $0.parametric.count < MusicParametricBand.slots { $0.parametric.append(MusicParametricBand()) } } }
                    .font(Typography.caption).foregroundStyle(accent).buttonStyle(.plain)
                    .disabled(eq.parametric.count >= MusicParametricBand.slots).atlas("control.music.eqAddBand")
            }
            ForEach(shown.parametric.indices, id: \.self) { i in bandRow(i) }
            if eq.parametric.isEmpty {
                Text("Place a band anywhere from 20 Hz to 20 kHz, with the width you want. Up to six.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
    }

    @ViewBuilder private func bandRow(_ i: Int) -> some View {
        if i < shown.parametric.count {
            let b = shown.parametric[i]
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("", isOn: Binding(get: { b.enabled }, set: { on in commit { if i < $0.parametric.count { $0.parametric[i].enabled = on } } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent).accessibilityLabel("Band on").atlas("control.music.eqBandOn")
                    Picker("", selection: Binding(get: { b.shape }, set: { s in commit { if i < $0.parametric.count { $0.parametric[i].shape = s } } })) {
                        Text("Bell").tag(MusicParametricBand.Shape.bell)
                        Text("Low shelf").tag(MusicParametricBand.Shape.lowShelf)
                        Text("High shelf").tag(MusicParametricBand.Shape.highShelf)
                    }.labelsHidden().frame(width: 110).atlas("control.music.eqBandShape")
                    Spacer()
                    Text(verbatim: MusicEqualizerLogic.bandLabel(b.hz) + " Hz · " + MusicEqualizerLogic.gainLabel(b.gainDB)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary)
                    Button { commit { if i < $0.parametric.count { $0.parametric.remove(at: i) } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove band").atlas("control.music.eqRemoveBand")
                }
                slider("Frequency", value: MusicEqualizerExtrasLogic.position(forHz: b.hz), range: 0...1) { v in set(i) { $0.hz = MusicEqualizerExtrasLogic.hz(forPosition: v) } }
                slider("Gain", value: b.gainDB, range: MusicParametricBand.gainRange) { v in set(i) { $0.gainDB = (v * 2).rounded() / 2 } }
                if b.shape == .bell { slider("Width", value: log10(b.q), range: log10(MusicParametricBand.qRange.lowerBound)...log10(MusicParametricBand.qRange.upperBound)) { v in set(i) { $0.q = pow(10, v) } } }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(ColorTokens.lineStrong.opacity(0.15)))
        }
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, _ change: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).font(Typography.caption).frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { change($0) }), in: range) { editing in
                if !editing, let d = draft { draft = nil; commit { $0 = d } }
            }.accessibilityLabel(Text(label))
        }
    }

    /// Edits band `i` on the draft, so the sound follows the slider only when it is let go.
    private func set(_ i: Int, _ change: (inout MusicParametricBand) -> Void) {
        var d = draft ?? eq
        guard i < d.parametric.count else { return }
        change(&d.parametric[i])
        draft = d
    }

    // MARK: per output

    private var perOutput: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember for each output").font(Typography.bodyMedium)
                Text("Headphones and speakers each keep their own sound, and it comes back when you plug them in.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { profiles.remembers }, set: { profiles.remembers = $0 })).labelsHidden().toggleStyle(.switch).tint(accent)
                .accessibilityLabel("Remember for each output").atlas("control.music.eqRememberPerOutput")
        }
    }
}

enum MusicEqualizerExtrasLogic {
    /// "Centre", "Left 40%" or "Right 25%".
    static func balanceLabel(_ b: Double) -> String {
        guard abs(b) >= 0.01 else { return Localized.string("Centre") }
        let pct = Int((abs(b) * 100).rounded())
        return Localized.string(b < 0 ? "Left %@" : "Right %@", "\(pct)%")
    }

    /// A frequency on a log slider: 0 is 20 Hz, 1 is 20 kHz.
    static func hz(forPosition p: Double) -> Double {
        let r = MusicParametricBand.hzRange
        return (r.lowerBound * pow(r.upperBound / r.lowerBound, min(1, max(0, p)))).rounded()
    }
    static func position(forHz hz: Double) -> Double {
        let r = MusicParametricBand.hzRange
        return log(min(r.upperBound, max(r.lowerBound, hz)) / r.lowerBound) / log(r.upperBound / r.lowerBound)
    }
}
