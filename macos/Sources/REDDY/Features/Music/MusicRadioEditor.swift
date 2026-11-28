import SwiftUI

// Edit a station: its name, what it follows (add by typing, remove one at a time, at least one stays) and how adventurous it is.

struct MusicRadioEditor: View {
    @Bindable var hub: MusicHub
    let stationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var adding = ""
    @State private var working = false
    @State private var loaded = false

    private var station: RadioStation? { hub.radio.station(id: stationID) }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            Text(verbatim: Localized.string("Edit station")).font(Typography.title).accessibilityAddTraits(.isHeader)
            TextField(Localized.string("Station name"), text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
                .accessibilityLabel(Localized.string("Station name")).atlas("control.music.radioEditName")
            if let st = station {
                Text(verbatim: Localized.string("Follows")).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                VStack(spacing: MusicSpace.xxs) {
                    ForEach(st.seeds) { seed in
                        HStack(spacing: MusicSpace.sm) {
                            if seed.thumbs.isEmpty { Image(systemName: "sparkles").frame(width: 36, height: 36).foregroundStyle(ColorTokens.textTertiary) }
                            else {
                                MusicCoverImage(thumbs: seed.thumbs, artworkClass: .tile, corner: MusicCorner.card, seed: seed.id)
                                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: MusicCorner.card, style: .continuous))
                            }
                            Text(verbatim: seed.name).musicText(.body).lineLimit(1)
                            Spacer()
                            Button { remove(seed, from: st) } label: { Image(systemName: "minus.circle").foregroundStyle(ColorTokens.textSecondary) }
                                .buttonStyle(.plain).disabled(st.seeds.count <= 1)
                                .accessibilityLabel(Localized.string("Stop following %@", seed.name)).atlas("control.music.radioEditRemoveSeed")
                        }
                    }
                }
                HStack(spacing: MusicSpace.xs) {
                    TextField(Localized.string("Add an artist, song, genre or language"), text: $adding).textFieldStyle(.roundedBorder).onSubmit(add)
                        .accessibilityLabel(Localized.string("Add a seed")).atlas("control.music.radioEditAddField")
                    Button(Localized.string("Add"), action: add).musicButton(.secondary, size: .compact)
                        .disabled(MusicSuggest.trimmed(adding).isEmpty || working).atlas("control.music.radioEditAdd")
                }
                HStack(spacing: MusicSpace.xs) {
                    ForEach(RadioMode.allCases) { m in
                        MusicChip(title: m.title, selected: st.mode == m) { hub.radio.setMode(st.id, m) }.musicTooltip(verbatim: m.blurb)
                    }
                }
            }
            HStack {
                Spacer()
                Button(Localized.string("Done")) { saveName(); dismiss() }.musicButton(.primary).atlas("control.music.radioEditDone")
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 360, idealWidth: 440)
        .onAppear { if !loaded { name = station?.name ?? ""; loaded = true } }
    }

    private func saveName() { hub.radio.rename(stationID, to: name) }

    private func remove(_ seed: RadioSeed, from st: RadioStation) {
        guard st.seeds.count > 1 else { return }
        hub.radio.setSeeds(stationID, st.seeds.filter { $0.id != seed.id })
    }

    private func add() {
        let words = MusicSuggest.trimmed(adding)
        guard !words.isEmpty, !working, let st = station else { return }
        working = true
        Task {
            if let seed = await RadioSeedResolver.resolve(words, hub: hub), !st.seeds.contains(where: { $0.id == seed.id }) {
                hub.radio.setSeeds(stationID, st.seeds + [seed])
            }
            adding = ""; working = false
        }
    }
}
