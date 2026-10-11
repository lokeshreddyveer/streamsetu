import SwiftUI

/// Fills missing posters and summaries from TMDB with the person's own API key.
struct ArtworkSettingsView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var hasKey = false
    @State private var running = false
    @State private var progress = MetadataMatchService.Progress()
    @State private var message: String?
    @State private var failed = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                SecureField(hasKey ? "Replace key" : "Paste your TMDB API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Key") { save() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey { Button("Remove Key", role: .destructive) { try? container?.metadata.removeKey(); hasKey = false; say("Key removed.") } }
            } header: { Text("API key") } footer: {
                Text(hasKey ? "A key is saved in the Keychain on this device." : "Create a free account at themoviedb.org, then copy your API key (or read access token) from Settings → API.")
            }.listRowBackground(ColorTokens.surface)
            Section {
                Button { start() } label: { HStack { if running { ProgressView() }; Text(running ? "Matching… \(progress.done) of \(progress.total)" : "Match Missing Artwork") } }.disabled(!hasKey || running)
                if running { Button("Stop") { task?.cancel() } }
                Button("Test Key") { test() }.disabled(!hasKey || running)
                if let message { Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(failed ? .orange : .green).font(.callout) }
            } footer: { Text("Only the title and year are sent. Anything your playlist already provides is left alone.") }.listRowBackground(ColorTokens.surface)
            Section { Text(MetadataMatchService.attribution).font(.caption).foregroundStyle(.secondary) }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Artwork and Details").themed("Artwork and Details")
        .onAppear { hasKey = container?.metadata.hasKey ?? false }
    }

    private func say(_ m: String, failure: Bool = false) { message = m; failed = failure }

    private func save() {
        guard let svc = container?.metadata else { return }
        do { try svc.saveKey(key); key = ""; hasKey = svc.hasKey; say("Key saved.") } catch { say("The key could not be saved.", failure: true) }
    }

    private func test() {
        guard let svc = container?.metadata else { return }
        say("Checking…")
        Task { do { try await svc.verifyKey(); say("TMDB accepted the key.") } catch { say(error.localizedDescription, failure: true) } }
    }

    private func start() {
        guard let svc = container?.metadata, !running else { return }
        running = true; progress = .init(); message = nil
        task = Task {
            defer { running = false }
            do {
                let out = try await svc.run { p in Task { @MainActor in progress = p } }
                state.catalogVersion += 1
                say(out.looked == 0 ? "Nothing is missing artwork." : "Matched \(out.matched) of \(out.looked) titles." + (out.remaining > 0 ? " \(out.remaining) more are waiting; run it again." : ""))
            } catch is CancellationError { say("Stopped.") } catch { say(error.localizedDescription, failure: true) }
        }
    }
}
