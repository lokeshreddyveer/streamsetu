import SwiftUI

/// Recognise local songs by their sound. For each song it makes a fingerprint, asks AcoustID and shows what it found. Nothing is changed until the person presses a
/// button: "Fill empty details" only fills what the file leaves blank, "Use these details" replaces, and writing into the files is a separate switch.
struct MusicAcoustIDSheet: View {
    let hub: MusicHub
    let tracks: [MusicTrack]
    let close: () -> Void

    enum Row: Equatable {
        case waiting, working
        case matched(AcoustIDRecording, Double, [String])
        case ambiguous([AcoustIDRecording])
        case unconfirmed
        case problem(String)
    }

    @State private var rows: [String: Row] = [:]
    @State private var entries: [String: LocalEntry] = [:]
    @State private var running = false
    @State private var writeToFiles = false
    @State private var task: Task<Void, Never>?
    @State private var connecting = false

    private var local: [MusicTrack] { tracks.filter { $0.providerID == MusicStatsRules.localProviderID } }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Identify by sound")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { task?.cancel(); close() } label: { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.identifyClose")
            }
            Text(Localized.string("A short fingerprint of each song is sent to AcoustID. Your audio is never sent, and nothing changes until you choose.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.sm) { ForEach(local) { t in row(t) } }
            }
            Toggle(Localized.string("Also write the details into the music files"), isOn: $writeToFiles).toggleStyle(.switch).atlas("control.music.identifyWrite")
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420)
        .task { await start() }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $connecting) { MusicAcoustIDConnectSheet { connecting = false } }
    }

    @ViewBuilder private func row(_ t: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: t.title).font(MusicTokens.rowTitle).lineLimit(1)
            switch rows[t.uid] ?? .waiting {
            case .waiting: Text(Localized.string("Waiting")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            case .working: HStack(spacing: 6) { MusicLoadingIcon(size: MusicIconSize.small); Text(Localized.string("Listening…")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
            case .matched(let r, let confidence, let reasons):
                found(r, t, headline: Localized.string("Recognised (%@)", "\(Int((confidence * 100).rounded()))%"), reasons: reasons)
            case .ambiguous(let list):
                Text(Localized.string("More than one song fits. Choose the right one:")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                ForEach(list) { r in found(r, t, headline: nil, reasons: []) }
            case .unconfirmed: Text(Localized.string("Not recognised. The file keeps its own details.")).musicText(.secondary).foregroundStyle(ColorTokens.textTertiary)
            case .problem(let text): Text(verbatim: text).musicText(.secondary).foregroundStyle(ColorTokens.danger)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(ColorTokens.lineStrong.opacity(0.15)))
    }

    private func found(_ r: AcoustIDRecording, _ t: MusicTrack, headline: String?, reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let headline { Text(verbatim: headline).font(Typography.captionMedium).foregroundStyle(ColorTokens.success) }
            Text(verbatim: r.title + (r.artistLine.isEmpty ? "" : " · " + r.artistLine)).font(Typography.bodyMedium).lineLimit(2)
            if let g = r.releaseGroups.first { Text(verbatim: g).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
            HStack {
                Button(Localized.string("Fill empty details")) { apply(r, to: t, replace: false) }.musicButton(.secondary, size: .compact).atlas("control.music.identifyFill")
                Button(Localized.string("Use these details")) { apply(r, to: t, replace: true) }.musicButton(.primary, size: .compact).atlas("control.music.identifyReplace")
            }
        }
    }

    private func start() async {
        guard !running else { return }
        running = true
        let index = await LocalLibraryStore.shared.currentIndex()
        for t in local { entries[t.uid] = index.entry(id: t.id) }
        task = Task {
            for t in local {
                if Task.isCancelled { break }
                guard let e = entries[t.uid] else { rows[t.uid] = .problem(Localized.string("This song is no longer in your music folders.")); continue }
                rows[t.uid] = .working
                do {
                    let outcome = try await LocalRecordingIdentifier.shared.identify(e)
                    switch outcome.verdict {
                    case .match(let r, let c, let why): rows[t.uid] = .matched(r, c, why)
                    case .ambiguous(let list): rows[t.uid] = .ambiguous(list)
                    case .unconfirmed: rows[t.uid] = .unconfirmed
                    }
                } catch is CancellationError { break } catch {
                    rows[t.uid] = .problem(Self.message(error))
                    // A missing user key opens the connection; a refused one is checked first, because a link still waiting for approval is not a wrong key.
                    if case AcoustIDError.needsUserKey = error { connecting = true; break }
                    if case AcoustIDError.invalidKey = error, case .pending = await AcoustIDConnection().resolveInvalidKey() { rows[t.uid] = .problem(Localized.string("Waiting for your approval")); connecting = true; break }
                }
            }
            running = false
        }
        await task?.value
    }

    static func message(_ error: Error) -> String {
        switch error {
        case ChromaprintTool.Failure.notInstalled: Localized.string("This file could not be read for a fingerprint. Chromaprint's fpcalc tool, if installed, is tried as a fallback.")
        case ChromaprintTool.Failure.unsupported: Localized.string("Identifying by sound needs the Mac app.")
        case ChromaprintTool.Failure.timedOut: Localized.string("The file took too long to read.")
        case ChromaprintTool.Failure.unreadable: Localized.string("This file could not be read for a fingerprint.")
        case AcoustIDError.needsApplicationKey: Localized.string("Identifying by sound needs this app's AcoustID application key, which has not been added yet.")
        case AcoustIDError.needsUserKey: Localized.string("Connect your AcoustID account to recognise songs.")
        case AcoustIDError.invalidKey: Localized.string("AcoustID refused the key. Check it in Settings.")
        case AcoustIDError.rateLimited: Localized.string("AcoustID is busy. Try again in a moment.")
        case AcoustIDError.invalidFingerprint: Localized.string("AcoustID could not use this file's fingerprint.")
        default: Localized.string("Could not reach AcoustID. Check your connection.")
        }
    }

    private func apply(_ r: AcoustIDRecording, to t: MusicTrack, replace: Bool) {
        guard let e = entries[t.uid] else { return }
        let patch = AcoustIDMatcher.patch(for: r, entry: e, replace: replace)
        guard !patch.isEmpty else { MusicToasts.shared.show(Localized.string("Nothing needed filling in.")); return }
        let write = writeToFiles
        Task {
            let n = await LocalLibraryStore.shared.edit(ids: [e.id], patch: patch)
            if write { _ = await LocalLibraryStore.shared.writeTags(ids: [e.id], patch: patch) }
            MusicToasts.shared.success(Localized.plural(n, one: "Updated %@ song.", other: "Updated %@ songs."))
        }
    }
}

/// Settings rows for recognition by sound: the person's AcoustID key (kept in the Keychain) and whether the fingerprint tool is there.
struct MusicAcoustIDSettingsRows: View {
    @State private var key = ""
    @State private var hasKey = AcoustIDKeys().userKey != nil
    @State private var waiting = AcoustIDKeys().link?.state == .pending
    @State private var connecting = false
    @State private var note: String?
    private let toolPath = ChromaprintTool.locate()

    var body: some View {
        MusicSettingsRow(title: "AcoustID key", atlas: "control.music.settingsAcoustIDKey",
                         detail: waiting ? Localized.string("Waiting for your approval") : (hasKey ? Localized.string("A key is saved") : Localized.string("Not added")),
                         info: "Connect your AcoustID account, or paste your own key from acoustid.org (your account page). It lets the app ask AcoustID to recognise songs. It is kept in the Keychain and never shown again. Removing it here does not disconnect the app on AcoustID.") {
            HStack {
                SecureField(Localized.string("Paste your key"), text: $key).textFieldStyle(.roundedBorder).frame(width: 190).atlas("control.music.settingsAcoustIDField")
                Button(Localized.string("Save")) { save() }.disabled(key.isEmpty).atlas("control.music.settingsAcoustIDSave")
                Button(Localized.string("Connect AcoustID")) { connecting = true }.atlas("control.music.settingsAcoustIDConnect")
                if hasKey { Button(Localized.string("Remove")) { AcoustIDKeys().removeUserKey(); hasKey = false; waiting = false; note = nil }.atlas("control.music.settingsAcoustIDRemove") }
            }
            .sheet(isPresented: $connecting, onDismiss: { hasKey = AcoustIDKeys().userKey != nil; waiting = AcoustIDKeys().link?.state == .pending }) { MusicAcoustIDConnectSheet { connecting = false } }
        }
        MusicSettingsRow(title: "Fingerprint tool", atlas: "control.music.settingsFpcalc",
                         detail: Localized.string("Built in"),
                         info: toolPath == nil ? "Songs are recognised by a fingerprint the app makes itself, so nothing needs installing. If a file cannot be read that way, Chromaprint's fpcalc tool is used instead when it is installed." : "Songs are recognised by a fingerprint the app makes itself, so nothing needs installing. If a file cannot be read that way, the Chromaprint fpcalc tool you installed is used instead.") { EmptyView() }
        if let note { MusicNote(text: note, tone: .bad) }
    }

    private func save() {
        if AcoustIDKeys().setUserKey(key) { hasKey = true; key = ""; note = nil } else { note = Localized.string("That does not look like an AcoustID key.") }
    }
}
