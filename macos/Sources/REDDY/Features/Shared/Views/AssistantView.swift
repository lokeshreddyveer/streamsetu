import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
    /// Atlas entry ids Show-me can point at.
    var showMe: [String] = []
    var followUps: [String] = []
    /// Label -> Atlas entry id for chips that stand for an entry: tapped, they are answered by id.
    var followUpIDs: [String: String] = [:]
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

    /// What Setu's own answers were about, so "and on iPhone" or "how do I change it" can follow. In memory only.
    private var atlasConversation = AtlasConversation()

    /// Bumped when the person using the app changes; an answer that was asked for before that is dropped instead of shown to the next person.
    private var generation = 0
    private var request: Task<Void, Never>?
    /// The optional model's improvement of an answer already on screen. Cancelled by any new input.
    private var upgrade: Task<Void, Never>?

    /// Another profile is now using the app: the conversation, the suggestions and any answer still on its way belong to the one that left.
    func profileChanged() {
        generation += 1
        request?.cancel(); request = nil
        busy = false; status = nil; confirming = [:]
        atlasConversation.reset()
        reset()
    }

    func reset() {
        states = [:]
        messages = [.init(role: .assistant, text: "Hi, I’m Setu. Ask me what to watch, how something in the app works, what’s on TV, or tell me to change something: “a tense thriller under 2 hours”, “why is this buffering?”, “turn on subtitles by default”.")]
    }

    /// `look` says where the person is; it is read when the message is sent.
    func send(_ raw: String, container: AppContainer, look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?), viaAI: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        upgrade?.cancel(); upgrade = nil
        if messages.isEmpty { reset() }
        // A chip that stands for an Atlas entry is answered by that entry, not asked again as words.
        if !viaAI, let id = messages.last(where: { $0.role == .assistant })?.followUpIDs[text], let r = AtlasAssistant.entryReply(id: id, conversation: &atlasConversation, container: container) {
            messages.append(.init(role: .person, text: text))
            messages.append(.init(role: .assistant, text: r.text, proposals: r.proposals, showMe: r.showMe, followUps: r.chips, followUpIDs: Dictionary(zip(r.chips, r.chipIDs), uniquingKeysWith: { a, _ in a })))
            return
        }
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
        // Questions about the app itself (where a setting is, what a shortcut does, how to add a source) are answered from Setu's own index first: no model, no key, no network.
        if !viaAI, !container.assistantModelFirst, let r = AtlasAssistant.reply(text, conversation: &atlasConversation, container: container) {
            let shown = AssistantMessage(role: .assistant, text: r.text, proposals: r.proposals, showMe: r.showMe, followUps: r.chips, followUpIDs: Dictionary(zip(r.chips, r.chipIDs), uniquingKeysWith: { a, _ in a }))
            messages.append(shown)
            // The engine's answer is already on screen. When it was unsure, the optional model gets a few seconds to do better; the answer is replaced only if nothing else happened meanwhile.
            if r.decision != .confident {
                let gen = generation, count = messages.count
                upgrade = Task { [weak self] in
                    let better = await container.atlasModelReply(text)      // gives up after about 6 s by itself; cancelled by any new input
                    guard let self, !Task.isCancelled, let better, gen == self.generation, self.messages.count == count, let i = self.messages.firstIndex(where: { $0.id == shown.id }) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { self.messages[i].text = better.say; self.messages[i].proposals = better.proposals; self.messages[i].followUps = []; self.messages[i].followUpIDs = [:]; self.messages[i].note = better.fallbackNote }
                }
            }
            return
        }
        busy = true; status = "Thinking…"
        let here = look()
        let context = container.assistantSeesScreen ? container.assistantContext(screen: here.screen, openItem: here.item, searchText: here.search) : nil
        var history = messages.filter { !$0.text.isEmpty }.map { (person: $0.role == .person, text: $0.text) }
        if viaAI, !history.isEmpty { history[history.count - 1].text = text }      // the AI sees the words, not the button's label
        let asked = generation
        request = Task {
            do {
                let r = try await container.askAssistant(history: history, context: context, onStep: { [weak self] s in self?.status = s }, skipInstant: viaAI)
                let more = !(r.answer?.results.isEmpty ?? true) && container.aiAvailable
                guard asked == generation else { return }
                messages.append(.init(role: .assistant, text: r.say, summary: (r.answer?.results.isEmpty ?? true) ? [] : Array((r.answer?.intent.summary ?? []).prefix(5)), results: Array((r.answer?.results ?? []).prefix(12)),
                                      elsewhere: r.answer?.elsewhere ?? [], proposals: r.proposals, followUps: more ? Self.followUps : [], steps: r.steps, note: r.fallbackNote, askAIText: r.instant ? text : nil))
            } catch {
                guard asked == generation else { return }
                messages.append(.init(role: .assistant, text: Self.friendly(error, container: container)))
            }
            guard asked == generation else { return }
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
    @Environment(\.reddyAccent) private var accentFill
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { m in bubble(m).id(m.id).transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.96, anchor: m.role == .person ? .bottomTrailing : .bottomLeading).combined(with: .opacity), removal: .opacity)) }
                        if model.busy { ThinkingDots(status: model.status).id("busy").transition(.opacity) }
                        if model.messages.count <= 1 { moods }
                    }
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 28)
                }
                .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14) })     // a soft fade, never a hard cut
                .onChange(of: model.messages.count) { _, _ in withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) } }
                .onChange(of: model.busy) { _, b in if b { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("busy", anchor: .bottom) } } }
            }
            Divider().opacity(0.25)
            input
        }
        .animation(spring, value: model.messages.count)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.busy)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true).atlas("screen.assistant") }
        .onChange(of: container.profiles.activeID) { _, _ in
            // Whoever was using the app has changed: what was said and everything offered to them stays with them, and nothing they asked for is answered to the next person.
            model.profileChanged()
        }
        .onAppear { if model.messages.isEmpty { model.reset() }; focused = true; sees = container.assistantSeesScreen }
    }

    // MARK: header with the model switcher

    private var header: some View {
        HStack(spacing: 10) {
            ZStack { Circle().fill(LinearGradient(colors: [ColorTokens.accent, ColorTokens.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).onAccentLabel() }
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setu").font(.headline).foregroundStyle(ColorTokens.textPrimary)
                modelMenu
            }.layoutPriority(0)
            Spacer(minLength: 4)
            Button { sees.toggle(); container.assistantSeesScreen = sees } label: { Image(systemName: sees ? "eye" : "eye.slash").frame(width: Self.hit, height: Self.hit).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary)
                .help(sees ? "Setu can see which screen you are on, what is playing and library counts. Click to stop sharing." : "Setu sees only what you type. Click to share your screen and library counts.").accessibilityLabel(sees ? "Sharing your screen with Setu, tap to stop" : "Not sharing your screen, tap to share").atlas("screen.assistant")
            Button { withAnimation(spring) { model.reset() } } label: { Image(systemName: "arrow.counterclockwise").frame(width: Self.hit, height: Self.hit).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).help("New chat").accessibilityLabel("New chat").accessibilityIdentifier("setu.newChat").atlas("screen.assistant")
            Button(action: close) { Image(systemName: "xmark").frame(width: Self.hit, height: Self.hit).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).help("Close (Esc)").accessibilityLabel("Close assistant").accessibilityIdentifier("setu.close").atlas("screen.assistant")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)          // the title, model name and three buttons must fit one row; at the accessibility sizes they pushed the whole sheet wider than the screen (the answers below still scale)
    }

    /// What the person sees as the engine: never a raw model string.
    /// The header shows the short form; the full sentence is in the tooltip.
    private var headerStatus: String { let t = statusLabel; return t.hasPrefix("Built-in help") ? "Built-in help" : t }
    private var statusLabel: String {
        let cfg = container.ai.load()
        let a = AIClient.appleAvailability()
        return AtlasModelStatus.chip(appleReady: cfg.provider == .apple && a.ok, why: a.why, providerReady: cfg.provider != .apple && cfg.isReady, providerTitle: cfg.provider.title)
    }

    private var modelMenu: some View {
        let cfg = container.ai.load()
        _ = tick
        return Menu {
            let ready = AssistantModels.ready(container)
            if ready.isEmpty { Text("Add a key in Settings → Library") }
            ForEach(ready, id: \.self) { p in
                Menu(p.title + (p == cfg.provider ? "  ✓" : "")) {
                    Button("Default" + (p == cfg.provider && container.ai.load(p).model.isEmpty ? "  ✓" : "")) { choose(p, model: "") }
                    ForEach(AssistantModels.suggestions(p), id: \.self) { m in Button(m + (p == cfg.provider && cfg.effectiveModel == m ? "  ✓" : "")) { choose(p, model: m) } }
                }
            }
            Divider()
            Button((container.assistantCloudAllowed ? "✓ " : "") + "Allow online AI services") { container.assistantCloudAllowed.toggle(); tick += 1 }
            Text(container.assistantCloudAllowed ? "If a model fails, Setu tries the next one." : "Only the on-device model and your own Ollama are used.")
            Text("Other models: Settings → Library")
        } label: {
            HStack(spacing: 4) { Circle().fill(cfg.isReady ? Color.green : Color.secondary).frame(width: 6, height: 6); Text(headerStatus).font(.caption2.weight(.medium)).truncationMode(.tail).foregroundStyle(ColorTokens.textSecondary).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(ColorTokens.textTertiary) }
                .padding(.horizontal, 7).padding(.vertical, 2).background(ColorTokens.elevated.opacity(0.7), in: Capsule()).accessibilityLabel("Engine: \(statusLabel). Change")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(maxWidth: 240, alignment: .leading).help(statusLabel + ". Change the AI model").atlas("screen.assistant")
    }

    private func choose(_ p: AIProvider, model m: String) {
        var c = container.ai.load(p); c.model = m; container.ai.save(c)
        tick += 1
    }

    private var moods: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking").font(.caption.weight(.semibold)).foregroundStyle(ColorTokens.textSecondary)
            AssistantFlow(spacing: 6) {
                ForEach(Self.starters, id: \.self) { q in
                    Button { model.send(q, container: container, look: look) } label: { Text(q).font(.callout).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 11).padding(.vertical, 6).background(ColorTokens.accent.opacity(0.16), in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.accent.opacity(0.28))) }.buttonStyle(.plain).atlas("screen.assistant")
                }
            }
        }
    }

    private static let starters = ["What should I watch tonight?", "Something for date night", "What’s on TV now?", "Why is this buffering?", "How do I turn on subtitles?", "How much did I watch this week?"]

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.busy }

    /// Header buttons: a 44 pt tap area on iPhone and iPad, the compact 28 pt on the Mac.
    private static var hit: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $draft, prompt: Text("Ask Setu anything…").foregroundStyle(ColorTokens.textSecondary), axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).foregroundStyle(ColorTokens.textPrimary)
                .focused($focused).submitLabel(.send).onSubmit(send).padding(.vertical, 6).accessibilityLabel("Message to Setu").accessibilityIdentifier("setu.field")
                #if os(iOS)
                .onChange(of: draft) { _, new in          // a growing field takes Return as a new line: here Return sends (the key is labelled Send)
                    guard new.hasSuffix("\n") else { return }
                    draft = String(new.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if canSend { send() }
                }
                #endif
            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(canSend ? ColorTokens.onAccent(accentFill) : ColorTokens.textTertiary).frame(width: 28, height: 28).background(canSend ? ColorTokens.accent : ColorTokens.elevated, in: Circle()) }
                .buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send").accessibilityIdentifier("setu.send").help("Send (⌘↩)").atlas("screen.assistant")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: canSend)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 5)
        .background(ColorTokens.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(focused ? ColorTokens.accent.opacity(0.6) : ColorTokens.lineStrong))
        .padding(12)
    }

    private func send() { let t = draft; draft = ""; model.send(t, container: container, look: look) }

    /// A suggested action. Tapping it asks the authorizer first: the situation may have changed since it was offered. The icon shows what really happened.
    /// Points at the control on the screen. Nothing is changed: guide-only entries are only ever highlighted.
    private func showMeButton(_ id: String) -> some View {
        Button {
            #if os(iOS)
            close()          // the sheet would sit on top of the page Show me points at: close it, then start once it has gone
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ShowMeController.shared.start(entryID: id) }
            #else
            ShowMeController.shared.start(entryID: id)
            #endif
        } label: {
            HStack(spacing: 6) { Image(systemName: "scope"); Text("Show me") }
                .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(ColorTokens.accent.opacity(0.16), in: Capsule())
        }.buttonStyle(.plain).accessibilityHint("Highlights it on the screen").accessibilityIdentifier("setu.showMe").atlas("screen.assistant")
    }

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
                .background(ColorTokens.accent.opacity(finished ? 0.06 : 0.16), in: Capsule())
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
            HStack { Spacer(minLength: 40); Text(m.text).textSelection(.enabled).padding(.horizontal, 13).padding(.vertical, 9).background(ColorTokens.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).onAccentLabel().accessibilityLabel("You said: \(m.text)") }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !m.steps.isEmpty { Text(m.steps.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                if !m.summary.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 5) { ForEach(m.summary, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).background(ColorTokens.accent.opacity(0.16), in: Capsule()) } } }
                }
                // The greeting is never selectable: an open panel must not start with highlighted text.
                AssistantCardText(text: m.text, selectable: m.id != model.messages.first?.id)
                if let n = m.note { Text(n).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                if !m.results.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) { ForEach(m.results) { r in Button { open(r.item) } label: { AskCardCompact(result: r) }.buttonStyle(.plain).atlas("screen.assistant") } }
                    }
                }
                if !m.elsewhere.isEmpty { Text("Other titles not found in your library: " + m.elsewhere.prefix(8).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                ForEach(m.proposals) { p in proposalButton(p) }
                ForEach(m.showMe, id: \.self) { id in showMeButton(id) }
                if let again = m.askAIText, m.id == model.messages.last?.id, container.aiAvailable, !model.busy {
                    Button { model.send(again, container: container, look: look, viaAI: true) } label: {
                        Label("Not what you meant? Ask AI", systemImage: "sparkles").font(.caption).padding(.horizontal, 9).padding(.vertical, 4).overlay(Capsule().strokeBorder(ColorTokens.accent.opacity(0.6)))
                    }.buttonStyle(.plain).atlas("screen.assistant")
                }
                if !m.followUps.isEmpty, m.id == model.messages.last?.id {
                    if m.followUpIDs.isEmpty {
                        AssistantFlow(spacing: 6) { ForEach(m.followUps, id: \.self) { f in Button { model.send(f, container: container, look: look) } label: { Text(f).font(.caption).foregroundStyle(ColorTokens.textPrimary).padding(.horizontal, 10).padding(.vertical, 5).background(ColorTokens.accent.opacity(0.14), in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.accent.opacity(0.3))) }.buttonStyle(.plain).atlas("screen.assistant") } }
                    } else {
                        // Topic choices: full-width rows that always show their words.
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(m.followUps, id: \.self) { f in
                                Button { model.send(f, container: container, look: look) } label: {
                                    HStack { Text(f).font(.callout).foregroundStyle(ColorTokens.textPrimary).multilineTextAlignment(.leading); Spacer(minLength: 6); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(ColorTokens.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }.buttonStyle(.plain).atlas("screen.assistant")
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: m.id != model.messages.first?.id ? 30 : 12, trailing: 12)).frame(maxWidth: .infinity, alignment: .leading)     // room under the content for the copy and regenerate buttons
            .background(ColorTokens.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ColorTokens.line))
            .overlay(alignment: .bottomTrailing) { if m.id != model.messages.first?.id { messageTools(m).padding(6) } }
            .accessibilityElement(children: .contain).accessibilityLabel("Setu")
        }
    }

    /// Copy and regenerate sit under an answer. Regenerate asks the same words again, by the same route.
    @ViewBuilder private func messageTools(_ m: AssistantMessage) -> some View {
        HStack(spacing: 2) {
            Button { AssistantClipboard.copy(m.text) } label: { Image(systemName: "doc.on.doc").font(.caption2).frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).help("Copy").accessibilityLabel("Copy answer").atlas("screen.assistant")
            if m.id == model.messages.last?.id, !model.busy, let q = model.messages.last(where: { $0.role == .person })?.text, !q.hasPrefix("Ask AI about") {
                Button { model.send(q, container: container, look: look) } label: { Image(systemName: "arrow.clockwise").font(.caption2).frame(width: 24, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).help("Ask again").accessibilityLabel("Ask again").atlas("screen.assistant")
            }
        }
    }
}


enum AssistantClipboard {
    @MainActor static func copy(_ t: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = t
        #endif
    }
}

/// An answer drawn as a card: numbered steps get a badge, a path reads as a breadcrumb, everything else is plain text.
struct AssistantCardText: View {
    let text: String
    var selectable = true
    static func steps(_ text: String) -> [(n: Int, say: String)] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let dot = l.firstIndex(of: "."), let n = Int(l[..<dot]) else { return nil }
            return (n, String(l[l.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
        }
    }
    static func breadcrumb(_ s: String) -> String { s.replacingOccurrences(of: " > ", with: " › ") }
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let step = Self.steps(line).first {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(step.n)").font(.caption2.weight(.bold)).onAccentLabel().frame(width: 18, height: 18).background(ColorTokens.accent, in: Circle()).accessibilityHidden(true)
                        row(step.say)
                    }.accessibilityElement(children: .combine).accessibilityLabel("Step \(step.n): \(step.say)")
                } else { row(line) }
            }
        }
    }
    @ViewBuilder private func row(_ s: String) -> some View {
        let t = Text(AssistantText.attributed(Self.breadcrumb(s))).font(.body).foregroundStyle(ColorTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
        if selectable { t.textSelection(.enabled) } else { t }
    }
}

/// Three dots that pulse while Setu works, with what it is doing. Still when Reduce Motion is on.
struct ThinkingDots: View {
    var status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) { ForEach(0..<3, id: \.self) { i in ThinkingDot(index: i, animated: !reduceMotion && AppActivity.shared.isLive).id(!reduceMotion && AppActivity.shared.isLive) } }
            Text(status ?? "Thinking…").font(.caption).foregroundStyle(ColorTokens.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(ColorTokens.card.opacity(0.9), in: Capsule())
        .accessibilityElement(children: .combine).accessibilityLabel(status ?? "Thinking")
    }
}

/// One of the three dots; it pulses only while `animated` (not with Reduce Motion, not while the app is in the background or covered).
private struct ThinkingDot: View {
    let index: Int
    let animated: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(ColorTokens.accent).frame(width: 6, height: 6).opacity(animated ? (on ? 1 : 0.3) : 0.7)
            .animation(animated ? .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.15) : nil, value: on)
            .onAppear { on = true }
    }
}

/// Chips that wrap onto as many rows as they need.
struct AssistantFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(proposal.width ?? 320, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = layout(bounds.width, subviews)
        for (i, f) in r.frames.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size)) }
    }
    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var frames: [CGRect] = []
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: min(s.width, width), height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), frames)
    }
}

/// When the assistant's button is shown (kids mode, the welcome screens and an open keyboard hide it; an open chat keeps it).
enum AssistantButtonRules {
    static func visible(kidsMode: Bool, onboarding: Bool, keyboardUp: Bool, chatOpen: Bool) -> Bool {
        if kidsMode || onboarding { return false }
        return chatOpen || !keyboardUp
    }
}

/// The round button at the bottom right, and the chat that opens above it.
struct AssistantBubble: View {
    let container: AppContainer
    /// Room to leave under the bubble (a player bar, a tab bar).
    var bottomInset: CGFloat = 20
    /// While a long page scrolls down the button steps aside (it comes back with the bar): it never sits over content or next to the minimised bar.
    var receded = false
    var open: (LibraryItem) -> Void
    var look: @MainActor () -> (screen: String, item: LibraryItem?, search: String?)
    var perform: @MainActor (AssistantProposal) async -> AssistantOutcome
    @State private var isOpen = false
    @State private var model = AssistantModel()
    private let launcher = AssistantLauncher.shared
    #if os(iOS)
    @State private var keyboardUp = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    #if os(iOS)
    private var chat: some View {
        AssistantChatView(container: container, model: model, open: { item in isOpen = false; open(item) }, look: look, perform: perform, close: { isOpen = false })
    }

    /// iPhone and iPad: the same sparkles button, 48 pt (44 pt minimum tap area), above the bars. The chat is a bottom sheet on iPhone and a popover on a regular-width iPad.
    var body: some View {
        let shown = AssistantButtonRules.visible(kidsMode: container.parental.kidsMode, onboarding: false, keyboardUp: keyboardUp, chatOpen: isOpen)
        let away = receded && !isOpen
        let wide = sizeClass == .regular
        Group {
            if shown {
                Button(action: toggle) {
                    Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).onAccentLabel().frame(width: 48, height: 48)
                        .background(ColorTokens.accent, in: Circle()).shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Setu assistant").accessibilityIdentifier("setu.open")
                .padding(.trailing, 16).padding(.bottom, bottomInset)
                .opacity(away ? 0 : 1).offset(x: away && !reduceMotion ? 24 : 0).allowsHitTesting(!away).accessibilityHidden(away)
                .popover(isPresented: Binding(get: { isOpen && wide }, set: { if !$0 { isOpen = false } }), attachmentAnchor: .point(.top), arrowEdge: .bottom) { chat.frame(width: 380, height: 560) }.atlas("screen.assistant")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shown).animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: receded)
        .sheet(isPresented: Binding(get: { isOpen && !wide }, set: { if !$0 { isOpen = false } })) { chat.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .onChange(of: launcher.opens) { _, _ in
            guard !container.parental.kidsMode else { _ = launcher.take(); return }
            isOpen = true
            if let q = launcher.take() { model.send(q, container: container, look: look) }
        }
        .onChange(of: container.parental.kidsMode) { _, k in if k { isOpen = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .allowsHitTesting(shown)
    }
    #else
    var body: some View {
        if !container.parental.kidsMode {
            VStack(alignment: .trailing, spacing: 10) {
                Spacer(minLength: 0)
                if isOpen {
                    AssistantChatView(container: container, model: model, open: { item in open(item) }, look: look, perform: perform, close: { toggle() })
                        .frame(maxWidth: 400).frame(maxHeight: 600)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .background(ColorTokens.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom)))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
                }
                Button(action: toggle) {
                    Image(systemName: isOpen ? "xmark" : "sparkles").font(.system(size: 20, weight: .semibold)).onAccentLabel().frame(width: 52, height: 52)
                        .background(ColorTokens.accent, in: Circle()).shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain).help("Assistant").accessibilityLabel(isOpen ? "Close assistant" : "Open assistant").atlas("screen.assistant")
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

    #endif

    private func toggle() { withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() } }
}
