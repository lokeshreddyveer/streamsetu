import SwiftUI

/// Fills missing posters and summaries from TMDB with the person's own API key.
struct ArtworkSettingsView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var hasKey = false
    @State private var trending = true
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
                if hasKey { Button("Remove Key", role: .destructive) {
                    do { try container?.metadata.removeKey(); hasKey = false; container?.smartMix.applyPolicy(); container?.smartMix.invalidate(.prefsChange); say("Key removed.") }
                    catch { say("Could not remove the key: \(error.localizedDescription)", failure: true) }
                } }
            } header: { Text("API key") } footer: {
                Text(hasKey ? "A key is saved in the Keychain on this device." : "Create a free account at themoviedb.org, then copy your API key (or read access token) from Settings → API.")
            }.glossRow()
            Section {
                Button { start() } label: { HStack { if running { ProgressView() }; Text(running ? "Matching… \(progress.done) of \(progress.total)" : "Match Missing Artwork") } }.disabled(!hasKey || running)
                if running { Button("Stop") { task?.cancel() } }
                Button("Test Key") { test() }.disabled(!hasKey || running)
                if let message { Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(failed ? .orange : .green).font(.callout) }
            } footer: { Text("Only the title and year are sent. Anything your playlist already provides is left alone.") }.glossRow()
            Section {
                Toggle("Use TMDB weekly trending", isOn: Binding(get: { trending }, set: { trending = $0; container?.smartMix.trendingEnabled = $0 }))
            } footer: { Text(hasKey ? "Ranks Top This Week and Trending in Your Library by this week's trending titles. Only the public list is requested." : "On by default, but it only works once you add your own TMDB key above.") }.glossRow()
            Section { TMDBAttribution() }.glossRow()
        }
        .navigationTitle("Artwork and Details").themed("Artwork and Details")
        .onAppear { hasKey = container?.metadata.hasKey ?? false; trending = container?.smartMix.trendingEnabled ?? true }
    }

    private func say(_ m: String, failure: Bool = false) { message = m; failed = failure }

    private func save() {
        guard let svc = container?.metadata else { return }
        do { try svc.saveKey(key); key = ""; hasKey = svc.hasKey; container?.smartMix.applyPolicy(); container?.smartMix.refreshTrendingIfNeeded(); say("Key saved.") } catch { say("The key could not be saved.", failure: true) }
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
