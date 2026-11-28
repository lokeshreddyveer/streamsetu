import SwiftUI

/// "Choose another audio source": every enabled audio provider's candidate recordings for one song. Picking one remembers it for that song only.
struct MusicAlternativesSheet: View {
    let hub: MusicHub
    let track: MusicTrack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reddyAccent) private var accent
    @State private var candidates: [MusicAudioSource] = []
    @State private var loading = true
    @State private var selection: String?

    private var overrides: MusicMatchOverrides { hub.matchOverrides }
    private var chosenUID: String? { overrides.entry(for: track).map { $0.providerID + ":" + $0.sourceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if hub.registry.audio.isEmpty {
                MusicEmptyState(symbol: "waveform.slash", title: Localized.string("No audio source is on"), message: Localized.string("Turn on an audio source in Settings first."))
            } else if loading {
                MusicLoadingView()
            } else if candidates.isEmpty {
                MusicEmptyState(symbol: "magnifyingglass", title: Localized.string("No other recordings found"), message: Localized.string("None of your audio sources has this song."))
            } else {
                ScrollView { LazyVStack(spacing: 2) { ForEach(candidates) { row($0) } } }.scrollIndicators(.hidden)
            }
            footer
        }
        .padding(20).frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .background(ColorTokens.background)
        .task(id: track.uid) {
            loading = true
            let found = await overrides.candidates(for: track, registry: hub.registry)
            if !Task.isCancelled { candidates = found; loading = false; selection = chosenUID }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MusicArtwork(track: track, size: 48, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose another audio source").font(Typography.title).accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(track.title) · \(track.displayArtistLine)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ s: MusicAudioSource) -> some View {
        let picked = selection == s.uid
        return Button { selection = s.uid } label: {
            HStack(spacing: 10) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").foregroundStyle(picked ? accent : ColorTokens.textTertiary).accessibilityHidden(true)
                MusicArtwork(s.thumbnails, size: 36, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: s.title).font(Typography.rowMedium).lineLimit(1)
                    Text(verbatim: s.artist ?? Localized.string("Unknown artist")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let ms = s.durationMs, ms > 0 { Text(verbatim: MusicTime.clock(ms: ms)).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary) }
                Text(verbatim: "\(Int((min(1, max(0, MusicStreamResolver.score(track: track, candidate: s))) * 100).rounded()))% match")
                    .font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
                Text(verbatim: hub.providerName(s.providerID)).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
                if s.uid == chosenUID { Text("In use").font(Typography.micro).foregroundStyle(accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            .background(picked ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: LayoutTokens.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain).hoverHighlight()
        .accessibilityLabel("\(s.title), \(s.artist ?? "unknown artist"), from \(hub.providerName(s.providerID))")
        .accessibilityAddTraits(picked ? .isSelected : []).atlas("control.music.chooseAnotherSourceSArtist")
    }

    private var footer: some View {
        HStack {
            Button("Reset to automatic") { hub.resetAudioSource(for: track); selection = nil }
                .musicButton(.secondary).disabled(!overrides.hasOverride(for: track)).accessibilityLabel("Reset to automatic matching").atlas("control.music.chooseAnotherSourceResetToAutomaticMatching")
            Spacer()
            Button("Cancel") { dismiss() }.musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.chooseAnotherSourceCancel")
            Button("Use this for this song") {
                if let s = candidates.first(where: { $0.uid == selection }) { hub.useAudioSource(s, for: track) }
                dismiss()
            }
            .musicButton(.primary).disabled(selection == nil || selection == chosenUID).keyboardShortcut(.defaultAction)
            .accessibilityLabel("Use the selected recording for this song").atlas("control.music.chooseAnotherSourceUseTheSelectedRecordingForThis")
        }
    }
}
