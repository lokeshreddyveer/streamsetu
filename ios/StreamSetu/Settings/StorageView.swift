import SwiftUI

/// Storage use, database checks, diagnostics and resets.
struct StorageView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var storage = StorageBreakdown()
    @State private var message: String?
    @State private var working = false
    @State private var confirm: Reset?
    @State private var report: URL?

    enum Reset: Identifiable { case history, everything; var id: Self { self } }

    var body: some View {
        List {
            Section("Storage on this device") {
                LabeledContent("Library database", value: bytes(storage.database))
                LabeledContent("Artwork cache", value: bytes(storage.artworkCache))
                LabeledContent("Temporary files", value: bytes(storage.temporary))
                LabeledContent("Total", value: bytes(storage.total))
                Button("Clear Artwork Cache") { run { await container?.artwork.clear(); return "Artwork cache cleared." } }
                Button("Clear Temporary Files") { run { let r = container?.maintenance.clearTemporaryFiles(); return "Removed \(r?.files ?? 0) temporary files." } }
            }.listRowBackground(ColorTokens.surface)
            Section("Library maintenance") {
                Button("Optimize Database") { run { try container?.maintenance.optimizeDatabase().summary ?? "" } }
                Button("Check Database Integrity") { run { let r = try container?.maintenance.verifyDatabase(); return r?.ok == true ? "The database is healthy (schema v\(r?.schemaVersion ?? 0))." : "Problems found: \(r?.problems.joined(separator: "; ") ?? "")" } }
                Button("Rebuild Search Index") { run { try container?.maintenance.rebuildSearchIndex(); state.catalogVersion += 1; return "Search index rebuilt." } }
            }.listRowBackground(ColorTokens.surface)
            if let message { Section { Text(message).font(.callout) }.listRowBackground(ColorTokens.surface) }
            Section {
                Button("Create Diagnostic Report") { makeReport() }
                if let report { ShareLink(item: report) { Label("Share Report", systemImage: "square.and.arrow.up") } }
            } header: { Text("Diagnostics") } footer: { Text("Passwords, tokens and stream addresses are removed from the report.") }.listRowBackground(ColorTokens.surface)
            Section("Reset") {
                Button("Clear Watch History…", role: .destructive) { confirm = .history }
                Button("Remove Everything…", role: .destructive) { confirm = .everything }
            }.listRowBackground(ColorTokens.surface)
        }
        .overlay { if working { ProgressView().controlSize(.large) } }
        .navigationTitle("Storage and Maintenance").themed("Storage and Maintenance")
        .task { refresh() }
        .confirmationDialog(confirm == .everything ? "Remove everything?" : "Clear watch history?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .everything { Button("Remove Everything", role: .destructive) { run { try container?.dataReset.removeEverything(); state.reload(); return "Everything was removed." } } }
            else { Button("Clear History", role: .destructive) { run { try container?.dataReset.clearViewingHistory(); state.catalogVersion += 1; return "Watch history cleared." } } }
        } message: { Text(confirmMessage) }
    }

    private var confirmMessage: String {
        if confirm == .everything, let s = container?.dataReset.summary() { return s.removeAllLines.joined(separator: "\n") }
        return "Removes the list of what you watched and your resume points. Favourites and collections stay."
    }

    private func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .file) }

    private func refresh() {
        guard let c = container else { return }
        storage = c.maintenance.storage(artworkCacheBytes: StorageService.shared.cacheSize())
    }

    private func run(_ work: @escaping () async throws -> String) {
        working = true
        Task {
            do { message = try await work() } catch { message = (error as? LocalizedError)?.errorDescription ?? "That didn't work." }
            working = false; refresh()
        }
    }

    private func makeReport() {
        guard let c = container else { return }
        let text = c.diagnostics.report(playback: c.playback.current?.title, engines: ["Apple AVPlayer"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StreamSetu-diagnostics.txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8); report = url }
        catch { state.toasts.show("Could not write the report: \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
    }
}
