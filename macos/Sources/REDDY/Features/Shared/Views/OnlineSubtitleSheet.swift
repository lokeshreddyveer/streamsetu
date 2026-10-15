import SwiftUI

/// Finds subtitles for what is playing on OpenSubtitles and loads the one the person picks. Needs the person's free key and account, set in Settings.
struct OnlineSubtitleSheet: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var hits: [OnlineSubtitles.Hit]?
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Subtitles online").font(.headline); Spacer(); Button("Close") { dismiss() } }.padding(14)
            Divider()
            List {
                if let message { Text(message).foregroundStyle(.secondary) }
                else if hits == nil { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) } }
                ForEach(hits ?? []) { h in
                    Button { pick(h) } label: { HStack { Image(systemName: "captions.bubble"); Text(h.label).lineLimit(2); Spacer() }.contentShape(Rectangle()) }.buttonStyle(.plain).disabled(working)
                }
            }.listStyle(.plain)
        }
        .frame(minWidth: 380, minHeight: 360)
        .task { await search() }
    }

    private var account: OnlineSubtitles.Account { container.map { .load(from: $0.credentials) } ?? .init() }

    private func search() async {
        guard let c = container else { return }
        guard account.isComplete else { message = "Add your free OpenSubtitles key, account name and password in Settings, Playback."; return }
        let title = c.playback.currentSeries?.title ?? c.playback.title
        let language = c.settings.subtitleLanguages.first ?? "en"
        do {
            let found = try await OnlineSubtitles(account: account).search(title: title, year: nil, language: language)
            hits = found; if found.isEmpty { message = "No subtitles found for this title." }
        } catch { message = error.localizedDescription }
    }

    private func pick(_ h: OnlineSubtitles.Hit) {
        guard let c = container else { return }
        working = true
        Task {
            do { let url = try await OnlineSubtitles(account: account).download(h); if c.playback.loadSubtitleFile(url) { dismiss() } else { message = "This player cannot load a subtitle file. Switch to MPV." } }
            catch { message = error.localizedDescription }
            working = false
        }
    }
}

/// A box for a time. "1:23:45", "83:45" or seconds; Go jumps there.
struct GoToTimeSheet: View {
    var onGo: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to time").font(.headline)
            Text("Hours:minutes:seconds, for example 1:23:45.").font(.caption).foregroundStyle(.secondary)
            TextField("1:23:45", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(go)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Go", action: go).buttonStyle(.borderedProminent).disabled(PlaybackCoordinator.parseTime(text) == nil) }
        }
        .padding(18).frame(minWidth: 300).task { focused = true }
    }

    private func go() { if let t = PlaybackCoordinator.parseTime(text) { onGo(t); dismiss() } }
}

/// The three boxes for the OpenSubtitles key, account name and password, kept in the Keychain.
struct OpenSubtitlesFields: View {
    @Environment(\.container) private var container
    @State private var account = OnlineSubtitles.Account()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("API key", text: $account.key)
            TextField("Account name", text: $account.user)
            SecureField("Password", text: $account.password)
        }
        .textFieldStyle(.roundedBorder).padding(.vertical, 6)
        .task { if let c = container, !loaded { account = .load(from: c.credentials); loaded = true } }
        .onChange(of: account.key) { _, _ in save() }
        .onChange(of: account.user) { _, _ in save() }
        .onChange(of: account.password) { _, _ in save() }
    }

    private func save() { if loaded, let c = container { account.save(to: c.credentials) } }
}
