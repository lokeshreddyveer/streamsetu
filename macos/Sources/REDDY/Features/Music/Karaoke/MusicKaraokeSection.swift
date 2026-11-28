import SwiftUI

/// Settings for on-device vocal removal. Off by default; with no model installed it says so and does nothing.
struct MusicKaraokeSettingsSection: View {
    let hub: MusicHub
    @State private var center = MusicKaraokeCenter.shared
    @State private var confirmClear = false
    @State private var confirmDelete: String?
    @State private var disclosure: MusicKaraokeModelEntry?
    @State private var agreed = false

    private var models: MusicKaraokeModelManager { center.models }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            mainGroup
            modelGroup
            qualityGroup
            storageGroup
        }
        .atlasScreen("screen.music.karaoke")
        .onAppear { center.refreshCacheSize(); models.reload() }
        .sheet(item: $disclosure) { entry in disclosureSheet(entry) }
        .confirmationDialog("Delete this model?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete model", role: .destructive) {
                if let id = confirmDelete, models.delete(id) { center.modelDeleted(id) }
                confirmDelete = nil
            }.atlas("control.music.karaokeDeleteModel")
        } message: { Text("The model file is removed from this device. Prepared songs stay until you clear them.") }
        .confirmationDialog("Clear prepared songs?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { center.clearCache() }.atlas("control.music.karaokeClear")
        }
    }

    // MARK: Main

    private var mainGroup: some View {
        MusicSettingsGroup(title: "Karaoke", footer: models.bundledModel != nil
                           ? "Experimental. Takes the vocals out of songs on this device so you can sing along. The model is included in the app; nothing is downloaded."
                           : "Experimental. Takes the vocals out of songs on this device so you can sing along. Needs a model you download; nothing is downloaded until you agree.") {
            MusicToggleRow(title: "Remove vocals", isOn: Binding(get: { center.isEnabled }, set: { center.setEnabled($0) })).disabled(!center.isSetUp)
            MusicValueRow(title: "Status", value: center.statusText)
        }
    }

    // MARK: Models

    private var modelGroup: some View {
        MusicSettingsGroup(title: "Model", footer: models.bundledModel != nil
                           ? "The model is part of the app and runs on this device only."
                           : "Checked against its published size and fingerprint after it downloads.") {
            if models.installed.isEmpty && !models.hasCatalog { MusicNote(text: "No model is installed and none is offered yet.") }
            ForEach(models.installed.filter { $0.isBundled == true }) { m in
                MusicSettingsRow(title: Localized.string("Included: %@ (MIT licence)", m.name),
                                 detail: Localized.string("Built into the app. Nothing to download.")) { EmptyView() }
            }
            ForEach(models.installed.filter { $0.isBundled != true }) { m in
                MusicSettingsRow(title: m.name, detail: Self.modelLine(m.tier.title, m.sizeBytes)) {
                    HStack(spacing: Spacing.sm) {
                        if center.settings.modelID == m.id || (center.settings.modelID == nil && center.activeModel?.id == m.id) {
                            Text("In use").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        } else {
                            Button("Use") { center.update { $0.modelID = m.id; $0.tier = m.tier } }.musicButton().accessibilityLabel(Text(verbatim: Localized.string("Use %@", m.name))).atlas("control.music.karaokeUse")
                        }
                        Button("Delete", role: .destructive) { confirmDelete = m.id }.musicButton(.destructive, size: .compact)
                            .disabled(center.isEnabled && center.activeModel?.id == m.id).accessibilityLabel(Text(verbatim: Localized.string("Delete %@", m.name))).atlas("control.music.karaokeDelete")
                    }
                }
            }
            ForEach(models.catalog.filter { !models.isInstalled($0.id) }) { e in
                MusicSettingsRow(title: e.name, detail: Self.modelLine(e.tier.title, e.sizeBytes)) {
                    if models.downloadingID == e.id { downloadProgress } else {
                        Button("Get") { agreed = false; disclosure = e }.musicButton().disabled(models.isDownloading)
                            .accessibilityLabel(Text(verbatim: Localized.string("Get %@", e.name))).atlas("control.music.karaokeGet")
                    }
                }
            }
            if case .failed(let message) = models.state {
                MusicSettingsRow(title: "Download failed", detail: message) { Button("Dismiss") { models.dismissError() }.musicButton().atlas("control.music.karaokeDismiss") }
            }
        }
    }

    private static func modelLine(_ tier: String, _ bytes: Int64) -> String { "\(tier), " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    @ViewBuilder private var downloadProgress: some View {
        switch models.state {
        case .downloading(let got, let total):
            HStack(spacing: Spacing.sm) {
                ProgressView(value: total > 0 ? Double(got) / Double(total) : 0).frame(width: MusicTokens.settingsControlWidth / 2)
                Button("Cancel") { models.cancelDownload() }.musicButton().atlas("control.music.karaokeCancel")
            }
        case .verifying: Text("Checking").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        case .preparing: Text("Preparing").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        default: EmptyView()
        }
    }

    private func disclosureSheet(_ e: MusicKaraokeModelEntry) -> some View {
        let d = models.disclosure(for: e)
        return VStack(alignment: .leading, spacing: Spacing.md) {
            Text(verbatim: d.title).font(Typography.title)
            Text(verbatim: Localized.string("Download size: %1$@. It comes from %2$@.", d.size, d.host)).font(Typography.body)
            ScrollView { Text(verbatim: d.license).font(Typography.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(minHeight: 120, maxHeight: 220)
                .padding(Spacing.sm).background(ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: MusicTokens.radiusRow, style: .continuous))
            Toggle("I have read the licence and agree to download", isOn: $agreed).accessibilityLabel(Text("Agree to the licence and download")).atlas("control.music.karaokeAgreeToTheLicenceAndDownload")
            HStack {
                Spacer()
                Button("Not now") { disclosure = nil }.musicButton().keyboardShortcut(.cancelAction).atlas("control.music.karaokeNotNow")
                Button(Localized.string("Download %@", d.size)) { models.download(e, userAgreed: agreed); disclosure = nil }
                    .musicButton(.primary).disabled(!agreed).keyboardShortcut(.defaultAction).atlas("control.music.karaokeDownload")
            }
        }
        .padding(Spacing.xl).frame(minWidth: MusicTokens.sheetWidth, idealWidth: MusicTokens.setupCardWidth)
    }

    // MARK: Quality and processor

    private var qualityGroup: some View {
        MusicSettingsGroup(title: "Quality and processor") {
            if Set(models.installed.map(\.tier)).count > 1 || models.hasCatalog {
            MusicPickerRow(title: "Quality", info: center.settings.tier.detail,
                           selection: Binding(get: { center.settings.tier }, set: { t in center.update { $0.tier = t; $0.modelID = nil } }),
                           options: MusicKaraokeTier.allCases.map { ($0, $0.title) })
            }
            if MusicKaraokeProcessor.coreMLAvailable {
                MusicPickerRow(title: "Processor", info: "The processor is the safe default. Core ML also uses the graphics chip and is opt-in.",
                               selection: Binding(get: { center.settings.processor }, set: { p in center.update { $0.processor = p } }),
                               options: MusicKaraokeProcessor.allCases.map { ($0, $0.title) })
            }
            MusicValueRow(title: "Running on", value: center.processorInUse.map { $0 == .cpu ? Localized.string("The processor") : "Core ML" } ?? Localized.string("Not used yet this session"))
        }
    }

    // MARK: Storage

    private static let limits: [Int] = [1_024, 2_048, 5_120, 10_240]

    private var storageGroup: some View {
        MusicSettingsGroup(title: "Prepared songs", footer: "Kept so they start straight away next time. The least recently played go first when the limit is reached.") {
            MusicPickerRow(title: "Size limit", selection: Binding(get: { center.settings.cacheLimitMB }, set: { v in center.update { $0.cacheLimitMB = v } }),
                           options: Self.limits.map { ($0, "\($0 / 1_024) GB") } + (Self.limits.contains(center.settings.cacheLimitMB) ? [] : [(center.settings.cacheLimitMB, Localized.string("Custom (%d MB)", center.settings.cacheLimitMB))]))
            MusicSettingsRow(title: "In use") {
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: center.cacheBytes, countStyle: .file)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    Button("Clear") { confirmClear = true }.musicButton().disabled(center.cacheBytes == 0).accessibilityLabel(Text("Clear prepared songs")).atlas("control.music.karaokeClearPreparedSongs")
                }
            }
        }
    }
}

/// The karaoke switch for the lyrics panel footer. One click turns it on or off; the colour says how it is doing.
struct MusicKaraokeSwitch: View {
    let hub: MusicHub
    @State private var center = MusicKaraokeCenter.shared
    @State private var showNote = false
    @Environment(\.reddyAccent) private var accent

    private var snapshot: MusicKaraokeProgress {
        guard let t = hub.player.current else { return center.isSetUp ? .off : .notSetUp }
        return center.progress(for: t, position: hub.player.position)
    }

    private var tint: Color {
        guard center.isEnabled else { return ColorTokens.textSecondary }
        switch snapshot.phase {
        case .failed, .waitingToRetry: return ColorTokens.danger
        case .tooLong: return accent.opacity(0.5)
        case .notSetUp: return ColorTokens.textTertiary
        default: return accent
        }
    }

    var body: some View {
        let s = snapshot
        Button { toggle() } label: {
            ZStack {
                if center.isEnabled, s.phase == .preparing || s.phase == .queued {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, s.fraction)).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: "music.mic").font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(center.isEnabled ? MusicKaraokeStatusText.help(s) : (center.isSetUp ? "Karaoke: remove vocals" : "Karaoke is not set up"))
        .accessibilityLabel("Karaoke").atlas("control.music.karaoke")
        .accessibilityValue(center.isEnabled ? MusicKaraokeStatusText.line(s) : (center.isSetUp ? "Off" : "Not set up"))
        .accessibilityAddTraits(.isToggle)
        .popover(isPresented: $showNote) {
            Text("Karaoke is not set up. Add a model in Music settings, under Playback. Nothing is downloaded until you choose to.")
                .font(Typography.caption).padding(12).frame(width: 260)
        }
    }

    private func toggle() {
        guard center.isSetUp else { showNote = true; return }
        center.setEnabled(!center.isEnabled)
        if center.isEnabled {
            let p = hub.player
            let after = (p.index.map { Array(p.queue.dropFirst($0 + 1)) }) ?? []
            center.prefetch(current: p.current, upcoming: after, position: p.position)
        }
    }
}
