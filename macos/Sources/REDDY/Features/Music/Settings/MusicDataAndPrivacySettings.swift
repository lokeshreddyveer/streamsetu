import SwiftUI
import UniformTypeIdentifiers

/// The library backup as a file the person saves: the JSON written by `MusicLibrary.exportJSON`.
struct MusicBackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Export and import of the whole library as one file.
struct MusicBackupSettingsGroup: View {
    let hub: MusicHub
    @State private var exportFile: MusicBackupFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var note: String?

    var body: some View {
        MusicSettingsGroup(title: "Backup", footer: "Your library as one file you keep.") {
            MusicSettingsActions {
                Button("Export library…") { exportFile = MusicBackupFile(data: hub.library.exportJSON()); exporting = true }.accessibilityLabel(Text("Export your music library")).atlas("control.music.settingsDataAndPrivacyExportYourMusicLibrary")
                Button("Import library…") { importing = true }.accessibilityLabel(Text("Import a music library")).atlas("control.music.settingsDataAndPrivacyImportAMusicLibrary")
            }
            if let note { MusicNote(text: note) }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: "Music library") { result in
            if case .failure(let e) = result { note = hub.loadError(e) } else { note = Localized.string("Library saved.") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in importBackup(r) }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): note = hub.loadError(e)
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { _ = try hub.library.importJSON(try Data(contentsOf: url)); note = Localized.string("Library imported.") }
            catch { note = Localized.string("That file is not a music library backup.") }
        }
    }
}

/// What stays on this device, when a source is contacted, and the wipe.
struct MusicDataPrivacyGroup: View {
    let hub: MusicHub
    @State private var confirmWipe = false

    var body: some View {
        MusicSettingsGroup(title: "Your data", footer: "Likes, playlists, history and downloads stay on this device. There is no account and no analytics. A source contacts its service when you search, play or open a page.") {
            MusicButtonRow(title: "Delete all music data", button: "Delete…", role: .destructive) { confirmWipe = true }
        }
        .confirmationDialog("Delete all music data?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await hub.wipeAll() } }.atlas("control.music.settingsDataAndPrivacyDeleteEverything")
            Button("Cancel", role: .cancel) {}.atlas("control.music.settingsDataAndPrivacyCancel")
        } message: { Text("This removes your likes, playlists, followed artists, saved albums, history, downloads, stats and cached covers from this device. It cannot be undone.") }
    }
}

/// The last changes to which sources are on, so a source that is off when expected can be explained.
struct MusicSourceChangesGroup: View {
    let hub: MusicHub
    private let shown = 10

    var body: some View {
        let all = hub.registry.changeLog
        let rows = Array(all.suffix(shown).reversed())
        return MusicSettingsGroup(title: "Recent source changes", count: all.isEmpty ? nil : Localized.string("Last %d of %d", rows.count, all.count),
                                  footer: "Only a switch, the setup screen, a plugin or a wipe changes a source.") {
            if rows.isEmpty { MusicNote(text: "No changes yet.") }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, c in
                let name = hub.registry.provider(id: c.id).map { MusicSourceDisplay.name(for: $0.info) } ?? c.id
                MusicValueRow(title: name + " " + Localized.string(c.on ? "on" : "off"),
                                 value: Localized.string(Self.reasonLabel(c.reason)) + " · " + c.at.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private static func reasonLabel(_ r: MusicChangeReason) -> String {
        switch r { case .switch: "switch"; case .setup: "setup"; case .wipe: "wipe"; case .migration: "migration"; case .plugin: "add-on"; case .unregister: "removed"; case .newSource: "turned on because it is new" }
    }
}

struct MusicAboutGroup: View {
    var body: some View {
        MusicSettingsGroup(title: "About") {
            MusicValueRow(title: "Version", value: MusicSettingsPage.versionText)
        }
    }
}
