import SwiftUI

/// Settings for Trakt: the person's own Trakt app keys, sign-in by code, and the watchlist.
struct TraktPanel: View {
    let container: AppContainer
    @State private var clientID = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var result: String?

    private var trakt: TraktService { container.trakt }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Marks what you watch on Trakt and adds your Trakt watchlist to Watch Later. You use your own free Trakt app, so nothing goes through us. Nothing is sent for a Watch Privately play or in a kids profile.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Create your Trakt app (use urn:ietf:wg:oauth:2.0:oob as the redirect)", destination: URL(string: "https://trakt.tv/oauth/applications")!).font(.caption)
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            SecureField("Client Secret", text: $secret).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Keys") { trakt.app = TraktApp(clientID: clientID, secret: secret); result = "Saved." }.disabled(clientID.isEmpty || secret.isEmpty)
                if trakt.app.isComplete { Button("Remove Keys", role: .destructive) { trakt.signOut(); trakt.app = TraktApp(); clientID = ""; secret = ""; result = nil } }
            }
            switch trakt.state {
            case .notConfigured: Text("Add your keys to sign in.").font(.callout).foregroundStyle(.secondary)
            case .signedOut: Button("Sign In to Trakt") { trakt.beginSignIn() }.buttonStyle(.borderedProminent)
            case .waitingForCode(let code, let url):
                VStack(alignment: .leading, spacing: 6) {
                    Text("On another device, open \(url) and enter:").font(.callout)
                    Text(code).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    HStack { if let u = URL(string: url) { Link("Open It Here", destination: u) }; Button("Cancel") { trakt.cancelSignIn() } }
                    ProgressView().controlSize(.small)
                }
            case .signedIn:
                Label("Signed in to Trakt", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                HStack {
                    Button(busy ? "Reading…" : "Add My Watchlist to Watch Later") { importList() }.disabled(busy)
                    Button("Sign Out", role: .destructive) { trakt.signOut() }
                }
            }
            if let m = result ?? trakt.message { Text(m).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .animation(.easeInOut(duration: 0.2), value: trakt.state)
        .onAppear { let a = trakt.app; clientID = a.clientID; secret = a.secret }
    }

    private func importList() {
        busy = true; result = nil
        Task {
            do {
                let r = try await container.importTraktWatchlist()
                result = r.total == 0 ? "Your Trakt watchlist is empty." : "Trakt lists \(r.total). \(r.found) are in your library, \(r.added) added to Watch Later."
            } catch { result = error.localizedDescription }
            busy = false
        }
    }
}

/// Settings for a debrid account, and a box to play a link through it.
struct DebridPanel: View {
    let container: AppContainer
    @State private var account = DebridAccount()
    @State private var input = ""
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plays a link from a file host through your own debrid account. Your token stays in the Keychain and is sent only to the service you choose.\(DebridClient.magnetsAllowed ? " Magnet links work too." : " Magnet links are not supported in the iPhone and iPad apps.")")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Service", selection: $account.service) { ForEach(DebridService.allCases) { Text($0.title).tag($0) } }
            SecureField("API token (\(account.service.tokenHelp))", text: $account.token).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Token") { container.debrid.save(account); status = account.isComplete ? "Saved." : "Removed." }
                if account.isComplete { Button("Remove", role: .destructive) { account.token = ""; container.debrid.save(account); status = "Removed." } }
            }
            Divider()
            TextField(DebridClient.magnetsAllowed ? "Paste a link or magnet link" : "Paste a link", text: $input).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            Button(busy ? "Working…" : "Play") { play() }.buttonStyle(.borderedProminent).disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty || !account.isComplete)
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { account = container.debrid.load() }
    }

    private func play() {
        busy = true; status = nil
        Task {
            do { try await container.playDebrid(input); input = "" }
            catch { status = error.localizedDescription }
            busy = false
        }
    }
}

#if os(iOS)
/// iPhone and iPad: ask the AI what to watch.
struct AskAIScreen: View {
    @Environment(\.container) private var container
    var body: some View {
        if let container {
            ScrollView {
                AskAIView(container: container, open: { item in
                    switch item {
                    case .movie(let m): Play.movie(m, container)
                    case .series(let s): Task { await Play.series(s, container, privately: false) }
                    }
                }, search: nil)
            }.navigationTitle("Ask AI").themed("Ask AI")
        }
    }
}

/// iPhone and iPad: both in one settings page.
struct IntegrationsScreen: View {
    @Environment(\.container) private var container
    var body: some View {
        Form {
            if let container {
                Section("Trakt") { TraktPanel(container: container) }.listRowBackground(ColorTokens.surface)
                Section("Debrid") { DebridPanel(container: container) }.listRowBackground(ColorTokens.surface)
                Section("AI assistant") { AISettingsPanel(container: container) }.listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Trakt, Debrid and AI").themed("Trakt, Debrid and AI")
    }
}
#endif
