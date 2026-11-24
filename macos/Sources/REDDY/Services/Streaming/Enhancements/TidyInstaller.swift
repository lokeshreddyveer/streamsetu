import WebKit

/// Adds one service's Tidy / hidden-element rule list to its web view and takes it out again. It never creates a script or a message handler: a
/// content rule list only. Nothing is added while a kids profile is in use or the app is locked, for a service without page hosts, or when there is
/// nothing to hide. A compile failure does nothing.
@MainActor
final class TidyInstaller {
    private let definition: ProviderDefinition
    private let store: TidyStore
    private let restricted: () -> Bool
    private let ruleStore: () -> WKContentRuleListStore
    private weak var controller: WKUserContentController?
    private var added: WKContentRuleList?
    private var generation = 0

    init(definition: ProviderDefinition, store: TidyStore = .shared, restricted: @escaping () -> Bool = { EnhancementRuntime.shared.isRestricted() },
         ruleStore: @escaping () -> WKContentRuleListStore = { .default() }) {
        self.definition = definition; self.store = store; self.restricted = restricted; self.ruleStore = ruleStore
    }

    /// Whether a rule list is in the controller right now.
    var hasRuleList: Bool { added != nil }
    var identifier: String? { added?.identifier }

    /// Tidy pages is on, or something is hidden, and nothing forbids it.
    var wanted: Bool {
        let id = definition.id
        guard TidyRules.supports(id), !restricted(), definition.homeURL.scheme == "https" else { return false }
        return store.isEnabled(id) || !store.hidden(id).isEmpty
    }

    /// Makes the controller match what is wanted now (removes the old list first). Safe to call again at any time.
    func apply(to controller: WKUserContentController) {
        generation += 1
        if let list = added { (self.controller ?? controller).remove(list); added = nil }
        self.controller = controller
        guard wanted else { return }
        let g = generation, id = definition.id, on = store.isEnabled(id), hidden = store.hidden(id), ruleStore = ruleStore()
        Task { @MainActor [weak self, weak controller] in
            guard let list = await TidyRuleList.list(for: id, tidyOn: on, hidden: hidden, in: ruleStore) else { return }
            guard let self, let controller, self.generation == g, self.wanted, self.added == nil else { return }
            controller.add(list); self.added = list
        }
    }
}
