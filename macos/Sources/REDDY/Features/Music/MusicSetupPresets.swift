import Foundation

/// Which part of the setup list a source belongs to. A source that offers several things is listed once, under the first that applies.
enum MusicSetupGroup: Int, CaseIterable, Sendable {
    case metadata, audio, lyrics, scrobble

    static func of(_ p: any MusicProvider) -> MusicSetupGroup? {
        if p is any MusicMetadataProvider { return .metadata }
        if p is any MusicAudioProvider { return .audio }
        if p is any MusicLyricsProvider { return .lyrics }
        if p is any MusicScrobbleProvider { return .scrobble }
        return nil
    }
}

/// The default set of sources and what the setup screen holds while it is open.
enum MusicSetupPresets {
    /// The full YouTube Music provider: search, browse, audio and lyrics, no account.
    static let youTubeMusicID = "ytmusic"
    /// Reads the folders the person adds. Off until they switch it on in Settings.
    static let localFilesID = "local"

    /// Every built-in source that works without an account, except Local files. Sources that need an account are not part of it; they appear in
    /// Plugins & sources with "Add your account" when the person opens them. Installed plugins are never part of it.
    static func defaultSet(providers: [any MusicProvider]) -> Set<String> {
        Set(providers.filter { $0.info.kind == .builtIn && $0.id != localFilesID && !$0.info.requiresSignIn }.map(\.id))
    }

    /// A set works when something in it finds music and something plays it (one source can do both).
    static func canContinue(_ ids: Set<String>, providers: [any MusicProvider]) -> Bool {
        let on = providers.filter { ids.contains($0.id) }
        return on.contains { $0 is any MusicMetadataProvider } && on.contains { $0 is any MusicAudioProvider }
    }

    @MainActor static func defaultSet(registry: MusicRegistry) -> Set<String> { defaultSet(providers: registry.all) }
}

/// What the setup screen holds: the ticked sources. A first run starts from the default set; running setup again starts from what is on now.
/// It never changes the registry; only Continue does, through `completeConsent`.
struct MusicSetupModel {
    let providers: [any MusicProvider]
    private(set) var chosen: Set<String>

    init(providers: [any MusicProvider], current: Set<String> = []) {
        self.providers = providers
        let known = Set(providers.map(\.id))
        let now = current.intersection(known)
        chosen = now.isEmpty ? MusicSetupPresets.defaultSet(providers: providers) : now
    }

    mutating func set(_ id: String, on: Bool) { if on { chosen.insert(id) } else { chosen.remove(id) } }
    mutating func selectRecommended(in group: MusicSetupGroup) { chosen.formUnion(recommended(in: group)) }
    mutating func turnOff(group: MusicSetupGroup) { chosen.subtract(ids(in: group)) }

    func ids(in group: MusicSetupGroup) -> Set<String> { Set(providers.filter { MusicSetupGroup.of($0) == group }.map(\.id)) }
    func recommended(in group: MusicSetupGroup) -> Set<String> { MusicSetupPresets.defaultSet(providers: providers).intersection(ids(in: group)) }
    func onCount(in group: MusicSetupGroup) -> Int { chosen.intersection(ids(in: group)).count }

    /// The exact set handed to `completeConsent(enabling:)`.
    var enabling: Set<String> { chosen }
    var canContinue: Bool { MusicSetupPresets.canContinue(chosen, providers: providers) }
}

/// The one place that decides how a source is named and described on the setup screen.
enum MusicSourceDisplay {
    /// Adapters of the same service get names that say what they add, so two rows are never both "YouTube Music".
    static func name(for info: MusicProviderInfo) -> String {
        switch info.id {
        case "youtube-music": "YouTube Music (basic search)"
        case "youtube": "YouTube Music lyrics"
        case MusicLyricsSources.ytCaptions: "YouTube captions"
        default: info.name
        }
    }

    static func isUnofficial(_ id: String) -> Bool { MusicLyricsSources.unofficial.contains(id) }

    /// The first sentence of a note, with its full stop.
    static func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: ". ") else { return t }
        return String(t[..<r.lowerBound]) + "."
    }

    /// One compact paragraph of what the chosen sources receive. Sources that only find lyrics share one sentence that names them;
    /// every other source contributes the first sentence of its own note, and repeated sentences appear once.
    static func sharedText(ids: Set<String>, providers: [any MusicProvider]) -> String {
        let chosen = providers.filter { ids.contains($0.id) }
        var sentences: [String] = []
        func add(_ s: String) { if !s.isEmpty, !sentences.contains(s) { sentences.append(s) } }
        let signIn = chosen.filter { $0.info.requiresSignIn }
        let lyricOnly = chosen.filter { MusicSetupGroup.of($0) == .lyrics && !$0.info.privacyNote.localizedCaseInsensitiveContains("nothing is sent anywhere") }
        let skipped = Set(lyricOnly.map(\.id)).union(signIn.map(\.id))
        for p in chosen where !skipped.contains(p.id) { add(firstSentence(p.info.privacyNote)) }
        if !signIn.isEmpty {
            add(Localized.string("%@ send nothing until you add your account.", signIn.map { name(for: $0.info) }.joined(separator: ", ")))
        }
        if lyricOnly.count > 2 {
            let names = lyricOnly.map { name(for: $0.info) }.joined(separator: ", ")
            add(Localized.string("While a song plays, its title and artist, and sometimes its album, length or video id, are sent to these %1$@ lyrics services: %2$@.", String(lyricOnly.count), names))
        } else {
            for p in lyricOnly { add(firstSentence(p.info.privacyNote)) }
        }
        return sentences.joined(separator: " ")
    }
}
