import AppIntents
import CoreSpotlight
import Foundation

/// A screen or a setting of StreamSetu that Spotlight and Shortcuts can name ("Hardware decoding", "Playback"). Only screens and settings: no how-tos, and nothing about locks, kids or hidden folders (see AtlasSpotlight).
struct AtlasEntryEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "StreamSetu Screen or Setting")
    static let defaultQuery = AtlasEntryQuery()

    let id: String
    let title: String
    let summary: String
    let location: String
    let words: [String]

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(location)") }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = title; set.displayName = title
        set.contentDescription = summary + (location.isEmpty ? "" : "\n" + location)
        set.keywords = words
        return set
    }

    @MainActor init(_ e: AtlasEntry) {
        id = e.id; title = e.title; summary = e.summary; location = e.path.joined(separator: " > ")
        words = Array(Set(e.aliases + e.path + [e.title]))
    }

    /// What may be indexed or offered right now on this device.
    @MainActor static func available() -> [AtlasEntryEntity] {
        AtlasSpotlight.indexable(Atlas.entries, platform: AtlasAssistant.platform, appStore: AtlasAssistant.appStore).map(AtlasEntryEntity.init)
    }
}

struct AtlasEntryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AtlasEntryEntity] {
        await MainActor.run { let ids = Set(identifiers); return AtlasEntryEntity.available().filter { ids.contains($0.id) } }
    }
    func entities(matching string: String) async throws -> [AtlasEntryEntity] {
        await MainActor.run {
            let allowed = Dictionary(AtlasEntryEntity.available().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let hits = Atlas.engine.retrieve(string, platform: AtlasAssistant.platform, appStore: AtlasAssistant.appStore, limit: 25).hits
            return hits.compactMap { allowed[$0.entry.id] }.prefix(10).map { $0 }
        }
    }
    func suggestedEntities() async throws -> [AtlasEntryEntity] {
        await MainActor.run { AtlasEntryEntity.available().filter { $0.id.hasPrefix("screen.ios.tab.") } }
    }
}

/// Opens a screen or setting from Spotlight or Shortcuts. It goes through the same link as everything else, so an app lock still holds it until the person unlocks.
struct OpenAtlasEntryIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a Screen or Setting"
    static let description = IntentDescription("Opens a screen or a setting in StreamSetu.")
    @Parameter(title: "Screen or setting") var target: AtlasEntryEntity

    @MainActor func perform() async throws -> some IntentResult {
        await IOSCoordinator.shared.boot()
        if let url = DeepLink.link(atlas: target.id) { IOSCoordinator.shared.open(url) }
        return .result()
    }
}

/// "Ask StreamSetu": Siri asks what you want to know and Setu answers on the device, with no key and no network.
struct AskSetuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Setu"
    static let description = IntentDescription("Ask how to do something in StreamSetu. Setu answers on your device.")
    static let openAppWhenRun = false
    @Parameter(title: "Question", requestValueDialog: "What would you like to know about StreamSetu?") var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask Setu \(\.$question)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        await IOSCoordinator.shared.boot()
        let text = Self.answer(question)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// The deterministic answer, or a plain reason there is none.
    @MainActor static func answer(_ question: String) -> String {
        guard AssistantFeature.isOn else { return "Setu is turned off for now." }
        guard let c = IOSCoordinator.shared.container else { return "StreamSetu is not ready yet. Open the app once and try again." }
        if c.appLock.enabled && c.appLock.isLocked { return "StreamSetu is locked. Unlock it, then ask again." }
        if c.parental.kidsMode { return "Setu is off while a kids profile is in use." }
        var conversation = AtlasConversation()
        guard let reply = AtlasAssistant.reply(question, conversation: &conversation, container: c) else {
            return "I do not have a sure answer to that. Open StreamSetu and ask Setu there, or try other words."
        }
        return reply.text
    }
}

/// Keeps the system index (Spotlight) in step with the Atlas: rebuilt when the Atlas text changes, emptied while a kids profile is in use.
@MainActor enum AtlasIndexer {
    private static var running = false

    static func refresh(_ c: AppContainer) {
        let defaults = UserDefaults.standard
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            if c.parental.kidsMode { await AtlasSpotlight.removeAll(); return }
            let entities = AtlasEntryEntity.available()
            let fp = AtlasSpotlight.fingerprint(AtlasSpotlight.indexable(Atlas.entries, platform: AtlasAssistant.platform, appStore: AtlasAssistant.appStore))
            guard defaults.string(forKey: AtlasSpotlight.hashKey) != fp else { return }
            do {
                try await CSSearchableIndex.default().deleteAllSearchableItems()
                try await CSSearchableIndex.default().indexAppEntities(entities)
                defaults.set(fp, forKey: AtlasSpotlight.hashKey)
            } catch { }
        }
    }
}
