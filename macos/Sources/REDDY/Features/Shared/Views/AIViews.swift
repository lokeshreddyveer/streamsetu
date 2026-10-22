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
            Text("Type a request in the search box, such as “telugu movies with mahesh babu” or “a tense thriller, not horror”. Picks appear above the results, found on this device. Choose an AI to have it read harder requests and pick the best of them. It is sent your words, and the titles and short plots of the few matches so it can choose between them; never your playlist address, logins or watch history. Pick one:")
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
            Toggle("Let the AI pick the best of the matches and say why", isOn: Binding(get: { container.settings.defaultsStore.object(forKey: "askai.judge") as? Bool ?? true }, set: { container.settings.defaultsStore.set($0, forKey: "askai.judge") })).font(.callout)
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

/// "What should I watch?": the words are understood (by the chosen AI if there is one, and always by the library's own cast index), and the answers come from the library on this device.
struct AskAIView: View {
    let container: AppContainer
    var open: (LibraryItem) -> Void
    var search: ((String) -> Void)?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var answer: AskAnswer?
    @State private var unwatchedOnly = false
    @State private var recents: [String] = []
    private static let recentsKey = "askai.recent"

    private var visible: [AskResult] { (answer?.results ?? []).filter { !unwatchedOnly || !$0.watched } }
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if container.parental.kidsMode {
                Text("The AI is not available in a kids profile.").foregroundStyle(.secondary)
            } else {
                Text(container.ai.load().isReady ? "Understanding with \(container.ai.provider.title)." : "No AI chosen: the words are read on this device. Choose one in Settings for harder requests.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(answer == nil ? "Telugu movies with Mahesh Babu, a tense thriller under 2 hours…" : "Refine: only unwatched, shorter, more like the first…", text: $text).textFieldStyle(.roundedBorder).onSubmit { ask(refining: answer != nil) }
                    Button(busy ? "Thinking…" : (answer == nil ? "Ask" : "Refine")) { ask(refining: answer != nil) }.buttonStyle(.borderedProminent).disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if answer != nil { Button("New") { answer = nil; text = ""; error = nil } }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if let a = answer { results(a) }
                else if !recents.isEmpty {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { r in Button { text = r; ask(refining: false) } label: { Label(r, systemImage: "clock.arrow.circlepath").lineLimit(1) }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: answer?.results.count)
        .onAppear { recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [] }
    }

    @ViewBuilder private func results(_ a: AskAnswer) -> some View {
        if !a.intent.summary.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(a.intent.summary, id: \.self) { Text($0).font(.caption).padding(.horizontal, 9).padding(.vertical, 4).background(Color.accentColor.opacity(0.18), in: Capsule()) } }
            }
        }
        Text(a.note).font(.callout).fixedSize(horizontal: false, vertical: true)
        HStack {
            Toggle("Unwatched only", isOn: $unwatchedOnly).font(.callout).fixedSize()
            Spacer()
            if let search, !a.intent.summary.isEmpty { Button("Open in Search") { search(a.intent.summary.joined(separator: " ")) }.buttonStyle(.borderless).font(.callout) }
        }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(visible) { r in
                    Button { open(r.item) } label: { AskCard(result: r) }.buttonStyle(.plain)
                }
            }
            if !a.elsewhere.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also in their filmography, not in your library").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(a.elsewhere.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }
            if a.intent.people.isEmpty == false, !a.usedTMDB, container.metadata.hasKey == false {
                Text("Add a TMDB key in Settings to also see the rest of their filmography.").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
    }

    private func ask(refining: Bool) {
        guard !busy else { return }
        let words = text.trimmingCharacters(in: .whitespaces)
        busy = true; error = nil
        Task {
            do {
                let a = try await container.askWhatToWatch(words, previous: refining ? answer?.intent : nil)
                withAnimation(.easeInOut(duration: 0.2)) { answer = a }
                if refining == false { remember(words) }
                text = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func remember(_ words: String) {
        var r = recents.filter { $0.caseInsensitiveCompare(words) != .orderedSame }; r.insert(words, at: 0)
        recents = Array(r.prefix(5)); UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }
}

/// A poster with its title and the reasons it was picked.
private struct AskCard: View {
    let result: AskResult
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if let u = result.item.posterURL.flatMap(URL.init(string:)) {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: result.item.isSeries ? "tv" : "film").foregroundStyle(.tertiary) }
                } else { Image(systemName: result.item.isSeries ? "tv" : "film").font(.title).foregroundStyle(.tertiary) }
                if result.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(5) }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(result.item.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text(result.reasons.filter { $0 != "Unwatched" && $0 != "Watched" }.prefix(2).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
    }
}


/// Inside the normal search: when what was typed reads like a request ("telugu movies with mahesh babu", "a tense thriller, not horror"), picks from the library appear above the usual
/// results. They are worked out on this device and cost nothing. When an AI has been chosen, "Ask AI" reads the words with it and lets it pick the best.
struct SmartPicksCard: View {
    let container: AppContainer
    let query: String
    var open: (LibraryItem) -> Void
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
                        if container.aiAvailable, !aiDone { Button(asking ? "Thinking…" : "Ask AI") { askAI() }.buttonStyle(.borderless).font(.callout).disabled(asking) }
                    }
                    Text(a?.note ?? (asking ? "Asking \(container.ai.provider.title)…" : "")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let a, !a.results.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(a.results.prefix(14)) { r in Button { open(r.item) } label: { AskCardCompact(result: r) }.buttonStyle(.plain) }
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
                error = container.metadata.hasKey ? nil : "No AI is set up. Add a key in Settings → Integrations to ask one, or a TMDB key to look up an actor's films."
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
                if let u = result.item.posterURL.flatMap(URL.init(string:)) { AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: result.item.isSeries ? "tv" : "film").foregroundStyle(.tertiary) } }
                else { Image(systemName: result.item.isSeries ? "tv" : "film").foregroundStyle(.tertiary) }
                if result.watched { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).padding(4) }
            }
            .frame(width: 96, height: 144).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(result.item.title).font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).frame(width: 96, alignment: .leading)
            Text(result.reasons.first { !["Unwatched", "Watched"].contains($0) } ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading).frame(width: 96, alignment: .leading)
        }
    }
}
