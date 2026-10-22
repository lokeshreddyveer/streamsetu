import SwiftUI

/// Settings for the AI: which one, its key and model, what it costs, and a test.
struct AISettingsPanel: View {
    let container: AppContainer
    @State private var config = AIConfig()
    @State private var testing = false
    @State private var status: String?

    private var store: AIStore { container.ai }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask for something to watch in your own words. Only the words you type are sent: never your playlist address, your logins, or what you have watched. Pick one:")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("AI", selection: Binding(get: { config.provider }, set: { config = store.load($0) })) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            if config.provider == .apple {
                let a = AIClient.appleAvailability()
                Label(a.why, systemImage: a.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(a.ok ? .green : .orange).font(.callout)
            }
            if config.provider.needsKey { SecureField("API key", text: $config.key).textFieldStyle(.roundedBorder) }
            if config.provider == .ollama { TextField("Address (http://192.168.1.20:11434)", text: $config.base).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
            if config.provider != .apple {
                TextField("Model (\(config.provider.defaultModel))", text: $config.model).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
            Text(config.provider.keyHelp).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost and limits (\(PricingNote.asOf))").font(.caption.weight(.semibold))
                Text(config.provider.pricing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(PricingNote.footer).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if let u = URL(string: config.provider.pricingURL) { Link("Check the provider's own page", destination: u).font(.caption) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Save") { store.save(config); status = "Saved." }
                Button(testing ? "Testing…" : "Test") { test() }.disabled(testing || !config.isReady)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { config = store.load() }
        .animation(.easeInOut(duration: 0.2), value: config.provider)
    }

    private func test() {
        store.save(config); testing = true; status = nil
        Task {
            do { _ = try await AIClient(config: config).ask(system: "Reply with the single word OK.", prompt: "Test"); status = "It works." }
            catch { status = error.localizedDescription }
            testing = false
        }
    }
}

/// "What should I watch?": the person's words go to the AI, and what comes back is matched against their own library on this device.
struct AskAIView: View {
    let container: AppContainer
    var open: (LibraryItem) -> Void
    var search: ((String) -> Void)?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var suggestion: WatchSuggestion?
    @State private var found: [LibraryItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if container.parental.kidsMode {
                Text("The AI is not available in a kids profile.").foregroundStyle(.secondary)
            } else if !container.ai.load().isReady {
                Text("Choose an AI in Settings first: Apple Intelligence needs no key.").foregroundStyle(.secondary)
            } else {
                Text("Using \(container.ai.provider.title). Only what you type is sent.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("A tense thriller, something light for the family, like Inception…", text: $text).textFieldStyle(.roundedBorder).onSubmit(ask)
                    Button(busy ? "Thinking…" : "Ask", action: ask).buttonStyle(.borderedProminent).disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if let s = suggestion {
                    if !s.note.isEmpty { Text(s.note).font(.callout) }
                    if !found.isEmpty {
                        Text("In your library").font(.subheadline.weight(.semibold))
                        ForEach(found) { item in
                            Button { open(item) } label: {
                                HStack { VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text([item.isSeries ? "Series" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } else if !s.titles.isEmpty { Text("None of the suggestions are in your library: \(s.titles.joined(separator: ", ")).").font(.callout).foregroundStyle(.secondary) }
                    if let search, !s.search.isEmpty { Button("Search my library for “\(s.search)”") { search(s.search) } }
                    let missing = s.titles.filter { name in !found.contains { TraktMatching.matches(listed: TraktListed(title: WatchAdvisor.split(name).name, year: WatchAdvisor.split(name).year, isShow: false), title: $0.title, year: $0.year) } }
                    if !missing.isEmpty && !found.isEmpty { Text("Not in your library: \(missing.joined(separator: ", "))").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: found.count)
    }

    private func ask() {
        guard !busy else { return }
        busy = true; error = nil; suggestion = nil; found = []
        Task {
            do { let r = try await container.askWhatToWatch(text); suggestion = r.suggestion; found = r.found }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
