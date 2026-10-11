import SwiftUI
import UniformTypeIdentifiers

/// Export, restore and automatic backups. A backup never contains passwords or full playlist addresses.
struct BackupView: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @Environment(AppState.self) private var state
    @State private var include = BackupOptions.standard
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var plan: RestorePlan?
    @State private var message: String?
    @State private var failed = false
    @State private var autoFiles: [URL] = []

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                option("Playlists (no passwords)", .sources)
                option("Collections", .collections)
                option("Favourites", .favorites)
                option("Preferences", .preferences)
                option("Folder order, hidden items, renames", .organisation)
                option("Viewing history and resume points", .history)
            } header: { Text("Include") }.listRowBackground(ColorTokens.surface)
            Section {
                Button("Create Backup…") { export() }
                if let exportURL { ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") } }
                Button("Restore from a File…") { importing = true }
            } footer: { Text("A restored playlist comes back switched off and asks for its login again.") }.listRowBackground(ColorTokens.surface)
            Section {
                Toggle("Back up automatically (weekly)", isOn: $s.autoBackup)
                if let d = s.lastAutoBackup { LabeledContent("Last automatic backup", value: d.formatted(.relative(presentation: .named))) }
                Button("Back Up Now") { _ = container?.autoBackup.runNow(); refresh(); say("Backup saved on this device.") }
                ForEach(autoFiles, id: \.self) { url in
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "StreamSetu-auto-", with: "")).font(.callout)
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        Button("Restore") { load(url) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            } header: { Text("Automatic backups") } footer: { Text("The latest five are kept in the app's storage on this device.") }.listRowBackground(ColorTokens.surface)
            if let message { Section { Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(failed ? .orange : .green).font(.callout) }.listRowBackground(ColorTokens.surface) }
        }
        .navigationTitle("Backup and Restore").themed("Backup and Restore")
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { r in
            guard case .success(let url) = r else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            load(url)
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { if $0 == nil { plan = nil } })) { box in
            NavigationStack {
                List {
                    Section("This backup contains") { ForEach(box.plan.summary, id: \.self) { Text($0) } }.listRowBackground(ColorTokens.surface)
                    Section { Button("Restore") { apply(box.plan) } } footer: { Text("Nothing is deleted. Items that are already here are merged, not duplicated.") }.listRowBackground(ColorTokens.surface)
                }
                .navigationTitle("Restore").themed("Restore").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { plan = nil } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private struct PlanBox: Identifiable {
        let plan: RestorePlan
        let id = UUID()
        init(_ plan: RestorePlan) { self.plan = plan }
    }

    private func option(_ title: String, _ o: BackupOptions) -> some View {
        Toggle(title, isOn: Binding(get: { include.contains(o) }, set: { if $0 { include.insert(o) } else { include.remove(o) } }))
    }

    private func say(_ m: String, failure: Bool = false) { message = m; failed = failure }
    private func refresh() { autoFiles = container?.autoBackup.existing() ?? [] }

    private func export() {
        guard let c = container else { return }
        do {
            let data = try c.backup.export(include, settings: settings, channelPrefs: c.playback.channelPrefs)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("StreamSetu-backup-\(Date().formatted(.iso8601.year().month().day())).json")
            try data.write(to: url, options: .atomic)
            exportURL = url; say("Backup created. Use Share to save it.")
        } catch { say("The backup could not be created.", failure: true) }
    }

    private func load(_ url: URL) {
        guard let c = container else { return }
        do { plan = try c.backup.plan(from: Data(contentsOf: url)) }
        catch { say((error as? LocalizedError)?.errorDescription ?? "That isn't a StreamSetu backup.", failure: true) }
    }

    private func apply(_ p: RestorePlan) {
        guard let c = container else { return }
        plan = nil
        do { let r = try c.backup.apply(p, settings: settings, channelPrefs: c.playback.channelPrefs); state.reload(); state.catalogVersion += 1; say(r.summary) }
        catch { say("The backup could not be restored.", failure: true) }
    }
}
