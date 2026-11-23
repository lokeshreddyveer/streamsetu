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
            Text("Type a request in the search box, such as “comedies from the 2010s with a favourite actor” or “a tense thriller, not horror”. Picks appear above the results, found on this device. Choose an AI to have it read harder requests and pick the best of them. It is sent your words, and the titles and short plots of the few matches so it can choose between them; never your playlist address, logins or watch history. Pick one:")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("AI", selection: Binding(get: { config.provider }, set: { config = store.load($0) })) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }.atlas("setting.aiProvider")
            if config.provider == .apple {
                let a = AIClient.appleAvailability()
                Label(a.why, systemImage: a.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(a.ok ? .green : .orange).font(.callout)
            }
            if config.provider.needsKey { SecureField("API key", text: $config.key).textFieldStyle(.roundedBorder) }
            if config.provider == .ollama { TextField("Address (http://192.168.1.20:11434)", text: $config.base).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
            Toggle("Let the AI pick the best of the matches and say why", isOn: Binding(get: { container.settings.defaultsStore.object(forKey: DefaultsKey.askAIJudge) as? Bool ?? true }, set: { container.settings.defaultsStore.set($0, forKey: DefaultsKey.askAIJudge) })).font(.callout).atlas("setting.askAIJudge")
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
                Button("Save") { store.save(config); status = "Saved." }.atlas("setting.aiProvider")
                Button(testing ? "Testing…" : "Test") { test() }.disabled(testing || !config.isReady).atlas("setting.aiProvider")
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


/// Inside the normal search: when what was typed reads like a request ("telugu movies with mahesh babu", "a tense thriller, not horror"), picks from the library appear above the usual
/// results. They are worked out on this device and cost nothing. When an AI has been chosen, "Ask AI" reads the words with it and lets it pick the best.
struct SmartPicksCard: View {
    let container: AppContainer
    let query: String
    var open: (LibraryItem) -> Void
    /// When set, a person named in the question gets a "Films of ..." button that opens the person screen (found by exact name).
    var openPerson: ((PersonRoute) -> Void)? = nil
    /// iPhone and iPad: a pick is a navigation link in the stack the card sits in.
    var useLinks = false
    /// Set on the "no results" page: the card is then shown whatever the words look like, and says what happened (the AI answering, or why it could not).
    var force = false
    @State private var answer: AskAnswer?
    @State private var showing = false
    @State private var asking = false
    @State private var error: String?
    @State private var aiDone = false

    var body: some View {
        VStack(spacing: 0) {
            // The work starts from a view that is always there: a task on an empty Group never runs.
            Color.clear.frame(height: 0).task(id: "\(query)|\(force)") { await refresh() }
            if showing, force || answer != nil {
                let a = answer
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text(aiDone ? "Picked for you" : "Smart picks").font(.subheadline.weight(.semibold))
                        ForEach((a?.intent.summary ?? []).prefix(4), id: \.self) { Text($0).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.16), in: Capsule()) }
                        Spacer()
                        if container.aiAvailable, !aiDone { Button(asking ? "Thinking…" : "Ask AI") { askAI() }.buttonStyle(.borderless).font(.callout).disabled(asking).atlas("control.search.askAI") }
                    }
                    Text(a?.note ?? (asking ? "Asking \(container.ai.provider.title)…" : "")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let openPerson, let a, !a.intent.people.isEmpty {
                        HStack(spacing: 12) { ForEach(a.intent.people.prefix(2), id: \.self) { n in Button("Films of \(n)") { openPerson(PersonRoute(name: n)) }.buttonStyle(.borderless).font(.callout).atlas("control.search.askAI") } }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let a, !a.results.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(a.results.prefix(14)) { r in
                                    if useLinks { NavigationLink(value: r.item) { AskCardCompact(result: r) }.buttonStyle(.plain).atlas("control.search.askAI") }
                                    else { Button { open(r.item) } label: { AskCardCompact(result: r) }.buttonStyle(.plain).atlas("control.search.askAI") }
                                }
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showing)
    }

    private func refresh() async {
        showing = false; aiDone = false; error = nil; answer = nil
        guard force || container.looksLikeARequest(query) else { return }
        try? await Task.sleep(nanoseconds: 450_000_000)          // wait for typing to pause
        if Task.isCancelled { return }
        if !force || !container.aiAvailable {
            if let a = try? await container.askWhatToWatch(query, useAI: false) { answer = a }
            else if force { error = "Searching the library failed." }
            showing = answer != nil || force
            if force, !container.aiAvailable, error == nil {
                error = container.metadata.hasKey ? nil : "No AI is set up. Add a key in Settings → Integrations to ask one, or an artwork and details key to look up an actor's films."
            }
        }
        // Nothing found from the library's own reading (a name whose films have not been read yet, say): ask the chosen AI straight away, as the person would have to anyway.
        if container.aiAvailable, answer?.results.isEmpty ?? true, !Task.isCancelled {
            showing = true; asking = true
            do { let ai = try await container.askWhatToWatch(query, useAI: true); if !Task.isCancelled { answer = ai; aiDone = true } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            asking = false
        }
    }

    private func askAI() {
        asking = true; error = nil
        Task {
            do { answer = try await container.askWhatToWatch(query, useAI: true); aiDone = true }
            catch { self.error = error.localizedDescription }
            asking = false
        }
    }
}

/// A small poster with the reason it was picked, for the strip inside search.
struct AskCardCompact: View {
    let result: AskResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if let u = result.item.posterURL, !u.isEmpty { ArtworkImage(url: u, kind: .poster, contentMode: .fill, symbol: result.item.isSeries ? "tv" : "film") }
                else { Image(systemName: result.item.isSeries ? "tv" : "film").foregroundStyle(.tertiary) }
                if result.watched { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).padding(4) }
            }
            .frame(width: 96, height: 144).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)).ratingBadge(result.item.credibleRating, scale: 0.7)
            Text(result.item.title).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).frame(width: 96, alignment: .leading)
            Text(result.reasons.first { !["Unwatched", "Watched"].contains($0) } ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading).frame(width: 96, alignment: .leading)
        }
    }
}
