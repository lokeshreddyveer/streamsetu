import SwiftUI

/// Settings → Library: fills missing posters and summaries from TMDB with the person's own API key.
struct ArtworkMatchingGroup: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var hasKey = false
    @State private var running = false
    @State private var progress = MetadataMatchService.Progress()
    @State private var message: SettingsMessage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        SettingsGroup(title: "Artwork and details", footer: "Fills in posters, summaries, years and ratings that your playlist doesn't provide, using The Movie Database with your own free API key. Only the title and year are sent. Anything your playlist already provides is left alone.") {
            SettingsRow(title: "TMDB API key", detail: hasKey ? "A key is saved on this Mac." : "Create a free account at themoviedb.org, then copy your API key (or read access token) from Settings → API.") {
                HStack(spacing: 8) {
                    SecureField(hasKey ? "Replace key" : "Paste key", text: $key).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(save)
                    Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey { Button("Remove", role: .destructive, action: remove) }
                }
            }
            SettingsActions {
                Button(action: start) { HStack(spacing: 6) { if running { ProgressView().controlSize(.small) } else { Image(systemName: "photo.on.rectangle.angled") }; Text(running ? "Matching… \(progress.done) of \(progress.total)" : "Match Missing Artwork") } }
                    .disabled(!hasKey || running)
                if running { Button("Stop") { task?.cancel() } }
                Button("Test Key") { test() }.disabled(!hasKey || running)
            }
            MessageLine(message: message)
            Text(MetadataMatchService.attribution).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { hasKey = container?.metadata.hasKey ?? false }
    }

    private func save() {
        guard let svc = container?.metadata else { return }
        do { try svc.saveKey(key); key = ""; hasKey = svc.hasKey; message = .init(text: "Key saved.", kind: .success) }
        catch { message = .init(text: "The key could not be saved.", kind: .failure) }
    }

    private func remove() {
        guard let svc = container?.metadata else { return }
        try? svc.removeKey(); hasKey = false; message = .init(text: "Key removed.", kind: .info)
    }

    private func test() {
        guard let svc = container?.metadata else { return }
        message = .init(text: "Checking…", kind: .info)
        Task { do { try await svc.verifyKey(); message = .init(text: "TMDB accepted the key.", kind: .success) }
               catch { message = .init(text: error.localizedDescription, kind: .failure) } }
    }

    private func start() {
        guard let svc = container?.metadata, !running else { return }
        running = true; progress = .init(); message = nil
        task = Task {
            defer { running = false }
            do {
                let out = try await svc.run { p in Task { @MainActor in progress = p } }
                state.catalogVersion += 1
                message = out.looked == 0 ? .init(text: "Nothing is missing artwork.", kind: .info)
                    : .init(text: "Matched \(out.matched) of \(out.looked) titles." + (out.remaining > 0 ? " \(out.remaining) more are waiting; run it again to continue." : ""), kind: out.matched > 0 ? .success : .info)
            } catch is CancellationError { message = .init(text: "Stopped.", kind: .info) }
            catch { message = .init(text: error.localizedDescription, kind: .failure) }
        }
    }
}
