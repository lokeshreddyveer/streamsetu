import Foundation

/// Where the optional model layer meets the assistant. Everything here is additive: with no model, with the switch off, in a kids profile or on any failure it returns nil and the existing paths run unchanged.
@MainActor extension AppContainer {
    /// Master switch for the model layer in Setu (on by default; it still needs a ready model and an unsure engine). Off means the engine alone answers.
    var atlasModelEnabled: Bool {
        get { settings.defaultsStore.object(forKey: "assistant.atlasModel") as? Bool ?? true }
        set { settings.defaultsStore.set(newValue, forKey: "assistant.atlasModel") }
    }

    /// "Friendly wording": the model rephrases the engine's facts. Off by default.
    var atlasFriendlyWording: Bool {
        get { settings.defaultsStore.object(forKey: "assistant.atlasFriendly") as? Bool ?? false }
        set { settings.defaultsStore.set(newValue, forKey: "assistant.atlasFriendly") }
    }

    /// On-device first (nothing leaves the device); otherwise the first model of the person's own chain, which already honours the online-services switch.
    func atlasLanguageModel() -> (any AtlasLanguageModel)? {
        guard atlasModelEnabled, !parental.kidsMode else { return nil }
        if AppleAtlasLanguageModel.isAvailable { return AppleAtlasLanguageModel() }
        guard let first = assistantModelChain().first(where: { $0.provider != .apple }) else { return nil }
        return ProviderAtlasLanguageModel(config: first)
    }

    /// A reply for a question the engine was unsure about, with the model choosing among the engine's own candidates. Nil when nothing was gained, so the caller carries on as before.
    func atlasModelReply(_ text: String, model injected: (any AtlasLanguageModel)? = nil) async -> AssistantReply? {
        guard !parental.kidsMode, AtlasAssistant.candidates(for: text) != nil, !AtlasAssistant.toolBacked.contains(AssistantRouter.route(text)) else { return nil }
        guard let model = injected ?? atlasLanguageModel() else { return nil }
        let engine = Atlas.engine
        var o = AtlasModelOptions(); o.timeout = 6; o.window = model.contextWindow
        let a = AIClient.appleAvailability()
        o.availability = model.isRemote || !(model is AppleAtlasLanguageModel) ? .available : AtlasModelAvailability.from(ok: a.ok, why: a.why)
        o.optedIn = assistantModelFirst; o.friendly = atlasFriendlyWording; o.remoteAllowed = assistantCloudAllowed; o.kids = parental.kidsMode
        let r = await AtlasModelAssist.resolve(text, engine: engine, conversation: AtlasConversation(), platform: AtlasAssistant.platform, appStore: AtlasAssistant.appStore, model: model, options: o,
                                               isStillOn: { true },
                                               accepts: { e, v in e.value?.settingKey.flatMap { AppSettingsCatalog.find($0) }.map { $0.changeable && $0.accepts(v) } ?? false },
                                               current: { AtlasAssistant.current($0, settings: self.settings) })
        guard r.assisted, atlasModelEnabled, !parental.kidsMode else { return nil }
        let packed = AtlasAssistant.package(r.answer, engine: engine, container: self)
        // Every proposal is checked by the authorizer now as well as when it is tapped.
        let ok = packed.proposals.filter { if case .deny = AssistantAuthorizer.check($0, container: self) { false } else { true } }
        var reply = AssistantReply(say: packed.text, proposals: ok)
        reply.fallbackNote = r.note
        return reply
    }
}
