import SwiftUI

/// One line of the conversation with the assistant.
struct AssistantMessage: Identifiable {
    enum Role { case person, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var summary: [String] = []
    var results: [AskResult] = []
    var elsewhere: [String] = []
    var proposals: [AssistantProposal] = []
    var followUps: [String] = []
    var steps: [String] = []
    var note: String?
    /// Set on an instant answer: the words the person typed, so they can be handed to the AI.
    var askAIText: String?
}

/// The chat: what was said, what the assistant is doing right now, and the work of answering. It lives as long as the app does, so closing the panel does not lose the conversation.
@MainActor @Observable
final class AssistantModel {
    var messages: [AssistantMessage] = []
    var busy = false
    /// What the assistant is doing at this moment ("Looking in your library…").
    var status: String?
    /// What happened to each suggested action: a tick is shown only for `.done`.
    enum ProposalState: Equatable { case running, done, failed(String), cancelled }
    var states: [UUID: ProposalState] = [:]
    /// Actions that need a preview confirmed first: the preview shown, waiting for the second tap.
    var confirming: [UUID: String] = [:]

    private static let followUps = AssistantRefinement.allCases.map(\.rawValue)

    func reset() {
        states = [:]
        messages = [.init(role: .assistant, text: "Hi, I’m Setu. Ask me what to watch, how something in the app works, what’s on TV, or tell me to change something: “a tense thriller under 2 hours”, “why is this buffering?”, “turn on subtitles by default”.")]
    }

    /// `look` says where the person is; it is read when the message is sent.
    func send(_ raw: String, container: AppContainer, look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?), viaAI: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if messages.isEmpty { reset() }
        // the button under an instant answer: the person's own words, handed to the AI
        messages.append(.init(role: .person, text: viaAI ? "Ask AI about “\(text)”" : text))
        // Plain commands ("go to live tv", "resume") are understood on the spot, with or without an AI.
        if let refinement = AssistantRefinement(rawValue: text), let shown = messages.last(where: { $0.role == .assistant && !$0.results.isEmpty }) {
            let r = AssistantRefinement.apply(refinement, to: shown.results, container: container)
            messages.append(.init(role: .assistant, text: r.say, results: r.results, proposals: r.results.first.map { [AssistantProposal(kind: .playItem(id: $0.item.id, isChannel: false, title: $0.item.title), origin: container.assistantOrigin(item: $0.item))] } ?? [], followUps: r.results.isEmpty ? [] : Self.followUps))
            return
        }
        if let offers = container.assistantCommandProposals(text) {
            messages.append(.init(role: .assistant, text: offers.count == 1 ? "I can do that:" : "I can do either of these:", proposals: offers))
            return
        }
        busy = true; status = "Thinking…"
        let here = look()
        let context = container.assistantSeesScreen ? container.assistantContext(screen: here.screen, openItem: here.item, searchText: here.search) : nil
        var history = messages.filter { !$0.text.isEmpty }.map { (person: $0.role == .person, text: $0.text) }
        if viaAI, !history.isEmpty { history[history.count - 1].text = text }      // the AI sees the words, not the button's label
        Task {
            do {
                let r = try await container.askAssistant(history: history, context: context, onStep: { [weak self] s in self?.status = s }, skipInstant: viaAI)
                let more = !(r.answer?.results.isEmpty ?? true) && container.aiAvailable
                messages.append(.init(role: .assistant, text: r.say, summary: (r.answer?.results.isEmpty ?? true) ? [] : Array((r.answer?.intent.summary ?? []).prefix(5)), results: Array((r.answer?.results ?? []).prefix(12)),
                                      elsewhere: r.answer?.elsewhere ?? [], proposals: r.proposals, followUps: more ? Self.followUps : [], steps: r.steps, note: r.fallbackNote, askAIText: r.instant ? text : nil))
            } catch {
                messages.append(.init(role: .assistant, text: Self.friendly(error, container: container)))
            }
            busy = false; status = nil
        }
    }

    /// Carries out a suggestion and records what really happened: running while it is being done, a tick only when it worked, otherwise the actual reason.
    func execute(_ p: AssistantProposal, perform: @MainActor (AssistantProposal) async -> AssistantOutcome) async {
        states[p.id] = .running
        let out = await perform(p)
        switch out {
        case .done(let m): states[p.id] = .done; if let m, !m.isEmpty { messages.append(.init(role: .assistant, text: m)) }
        case .failed(let m): states[p.id] = .failed(m); messages.append(.init(role: .assistant, text: m))
        }
    }

    private static func friendly(_ e: Error, container: AppContainer) -> String {
        let m = e.localizedDescription
        if m.lowercased().contains("limit") { return m + " You can switch to another model from the menu above." }
        return m + (container.ai.load().isReady ? " You can try again or switch model from the menu above." : "")
    }
}

/// Models worth offering for each provider. A name the provider does not know is reported by the provider; the default is always there.
enum AssistantModels {
    static func suggestions(_ p: AIProvider) -> [String] {
        switch p {
        case .gemini: ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .groq: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"]
        case .openAI: ["gpt-4o-mini", "gpt-4o"]
        case .claude: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .ollamaCloud: ["gpt-oss:120b", "gpt-oss:20b"]
        case .openRouter, .nvidia, .ollama, .apple: []
        }
    }
    /// The providers that can be used right now: on-device if available, and every one with a key (or an address) saved.
    @MainActor static func ready(_ container: AppContainer) -> [AIProvider] {
        AIProvider.allCases.filter { p in p == .apple ? AIClient.appleAvailability().ok : container.ai.load(p).isReady }
    }
}

/// The conversation itself: the messages, the poster strips and the box to type in. `open` shows a title; `perform` carries out a confirmed suggestion.
struct AssistantChatView: View {
    let container: AppContainer
    @Bindable var model: AssistantModel
    var open: (LibraryItem) -> Void
    /// Where the person is: the screen's name, the title page open (if any) and what is typed in search.
    var look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?)
    /// Carries out a confirmed suggestion; returns a sentence to show when there is one.
    var perform: @MainActor (AssistantProposal) async -> AssistantOutcome
    var close: () -> Void
    @State private var draft = ""
    @State private var sees = true
    @State private var tick = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { m in bubble(m).id(m.id) }
                        if model.busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.status ?? "Thinking…").font(.caption).foregroundStyle(.secondary) }.id("busy").transition(.opacity) }
                        if model.messages.count <= 1 { moods }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { _, _ in withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) } }
                .onChange(of: model.busy) { _, b in if b { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("busy", anchor: .bottom) } } }
            }
            Divider().opacity(0.4)
            input
        }
        .animation(.easeInOut(duration: 0.2), value: model.busy)
        .onChange(of: container.profiles.activeID) { _, _ in
            // Whoever was using the app has changed: nothing offered to them may run for the next person.
            let open = model.messages.flatMap(\.proposals).filter { model.states[$0.id] == nil || model.states[$0.id] != .done }
            guard !open.isEmpty else { return }
            open.forEach { if model.states[$0.id] != .running { model.states[$0.id] = .cancelled } }; model.confirming = [:]
            model.messages.append(.init(role: .assistant, text: "The profile changed, so I cancelled my earlier suggestions."))
        }
        .onAppear { if model.messages.isEmpty { model.reset() }; focused = true; sees = container.assistantSeesScreen }
    }

    // MARK: header with the model switcher

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Setu").font(.headline)
                modelMenu
            }
            Spacer()
            Button { sees.toggle(); container.assistantSeesScreen = sees } label: { Image(systemName: sees ? "eye" : "eye.slash") }.buttonStyle(.plain)
                .help(sees ? "Setu can see which screen you are on, what is playing and library counts. Click to stop sharing." : "Setu sees only what you type. Click to share your screen and library counts.").accessibilityLabel("Screen sharing")
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.reset() } } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).help("New chat").accessibilityLabel("New chat")
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close").accessibilityLabel("Close assistant")
        }
        .padding(12)
    }

    private var modelMenu: some View {
        let cfg = container.ai.load()
        _ = tick
        let label = cfg.isReady ? "\(cfg.provider.title)" + (cfg.provider == .apple ? "" : " · " + cfg.effectiveModel) : "No AI connected"
        return Menu {
            let ready = AssistantModels.ready(container)
            if ready.isEmpty { Text("Add a key in Settings → Integrations") }
            ForEach(ready, id: \.self) { p in
                Menu(p.title + (p == cfg.provider ? "  ✓" : "")) {
                    Button("Default" + (p == cfg.provider && container.ai.load(p).model.isEmpty ? "  ✓" : "")) { choose(p, model: "") }
                    ForEach(AssistantModels.suggestions(p), id: \.self) { m in Button(m + (p == cfg.provider && cfg.effectiveModel == m ? "  ✓" : "")) { choose(p, model: m) } }
                }
            }
            Divider()
            Button((container.assistantCloudAllowed ? "✓ " : "") + "Allow online AI services") { container.assistantCloudAllowed.toggle(); tick += 1 }
            Text(container.assistantCloudAllowed ? "If a model fails, Setu tries the next one." : "Only the on-device model and your own Ollama are used.")
            Text("Other models: Settings → Integrations")
        } label: {
            HStack(spacing: 3) { Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1); Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(.secondary) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change the AI model")
    }

    private func choose(_ p: AIProvider, model m: String) {
        var c = container.ai.load(p); c.model = m; container.ai.save(c)
        tick += 1
    }

    private var moods: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Self.starters, id: \.self) { q in
                Button { model.send(q, container: container, look: look) } label: { Text(q).font(.callout).padding(.horizontal, 10).padding(.vertical, 6).background(Color.accentColor.opacity(0.14), in: Capsule()) }.buttonStyle(.plain)
            }
        }
    }

    private static let starters = ["What should I watch tonight?", "Something for date night", "What’s on TV now?", "Why is this buffering?", "How do I turn on subtitles?", "How much did I watch this week?"]

    private var input: some View {
        HStack(spacing: 8) {
            TextField("Ask Setu anything…", text: $draft).textFieldStyle(.plain).focused($focused).onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.busy ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.busy).accessibilityLabel("Send")
        }
        .padding(12)
    }

    private func send() { let t = draft; draft = ""; model.send(t, container: container, look: look) }

    /// A suggested action. Tapping it asks the authorizer first: the situation may have changed since it was offered. The icon shows what really happened.
    @ViewBuilder private func proposalButton(_ p: AssistantProposal) -> some View {
        let state = model.states[p.id]
        let busy = state == .running, finished = state == .done || state == .cancelled
        VStack(alignment: .leading, spacing: 6) {
            Button { tap(p) } label: {
                HStack(spacing: 6) {
                    switch state {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark")
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .cancelled: Image(systemName: "xmark")
                    case nil: Image(systemName: p.symbol)
                    }
                    Text(busy ? p.title + " …" : p.title)
                }
                .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(finished ? 0.06 : 0.16), in: Capsule())
            }.buttonStyle(.plain).disabled(busy || finished)
            if let preview = model.confirming[p.id], state == nil {
                Text(preview).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Confirm") { var q = p; q.confirmed = true; model.confirming[p.id] = nil; run(q) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { model.confirming[p.id] = nil }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private func tap(_ p: AssistantProposal) {
        if let s = model.states[p.id], s != .running, case .failed = s {} else if model.states[p.id] != nil { return }
        switch AssistantAuthorizer.check(p, container: container) {
        case .deny(let why): model.states[p.id] = .failed(why); model.messages.append(.init(role: .assistant, text: why))
        case .confirm(let preview): model.confirming[p.id] = preview
        case .allow: run(p)
        }
    }

    private func run(_ p: AssistantProposal) {
        // Checked again here: confirming takes time too.
        if case .deny(let why) = AssistantAuthorizer.check(p, container: container) { model.states[p.id] = .failed(why); model.messages.append(.init(role: .assistant, text: why)); return }
        Task { await model.execute(p, perform: perform) }
    }

    @ViewBuilder private func bubble(_ m: AssistantMessage) -> some View {
        if m.role == .person {
            HStack { Spacer(minLength: 40); Text(m.text).textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 8).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).foregroundStyle(.white) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !m.steps.isEmpty { Text(m.steps.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                if !m.summary.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 5) { ForEach(m.summary, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.16), in: Capsule()) } } }
                }
                Text(AssistantText.attributed(m.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let n = m.note { Text(n).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                if !m.results.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) { ForEach(m.results) { r in Button { open(r.item) } label: { AskCardCompact(result: r) }.buttonStyle(.plain) } }
                    }
                }
                if !m.elsewhere.isEmpty { Text("Other titles not found in your library: " + m.elsewhere.prefix(8).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                ForEach(m.proposals) { p in proposalButton(p) }
                if let again = m.askAIText, m.id == model.messages.last?.id, container.aiAvailable, !model.busy {
                    Button { model.send(again, container: container, look: look, viaAI: true) } label: {
                        Label("Not what you meant? Ask AI", systemImage: "sparkles").font(.caption).padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
                    }.buttonStyle(.plain)
                }
                if !m.followUps.isEmpty, m.id == model.messages.last?.id {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(m.followUps, id: \.self) { f in Button { model.send(f, container: container, look: look) } label: { Text(f).font(.caption).padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4))) }.buttonStyle(.plain) } }
                    }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The round button at the bottom right, and the chat that opens above it.
struct AssistantBubble: View {
    let container: AppContainer
    /// Room to leave under the bubble (a player bar, a tab bar).
    var bottomInset: CGFloat = 20
    var open: (LibraryItem) -> Void
    var look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?)
    var perform: @MainActor (AssistantProposal) async -> AssistantOutcome
    @State private var isOpen = false
    @State private var model = AssistantModel()
    private let launcher = AssistantLauncher.shared

    var body: some View {
        if !container.parental.kidsMode {
            VStack(alignment: .trailing, spacing: 10) {
                Spacer(minLength: 0)
                if isOpen {
                    AssistantChatView(container: container, model: model, open: { item in open(item) }, look: look, perform: perform, close: { toggle() })
                        .frame(maxWidth: 380).frame(maxHeight: 560)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
                }
                Button(action: toggle) {
                    Image(systemName: isOpen ? "xmark" : "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 52, height: 52)
                        .background(Color.accentColor, in: Circle()).shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain).help("Assistant").accessibilityLabel(isOpen ? "Close assistant" : "Open assistant")
            }
            .padding(.trailing, 20).padding(.bottom, bottomInset).padding(.top, 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.easeInOut(duration: 0.2), value: isOpen)
            .onChange(of: launcher.opens) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) { isOpen = true }
                if let q = launcher.take() { model.send(q, container: container, look: look) }
            }
        }
    }

    private func toggle() { withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() } }
}
