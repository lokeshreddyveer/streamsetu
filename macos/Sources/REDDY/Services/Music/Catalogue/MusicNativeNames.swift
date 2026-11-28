import Foundation
import Observation

/// Shows a song in its own language and script: sources often give a title in Latin letters ("Mate Rani"), while the graph can hold the same song's name in the language it is
/// sung in ("మాటే రాణి"), from an alias a source tagged with that language. The lookup is by the song's language (its source's statement, its script, or the graph's record of its film or
/// album), never by a country, an artist or a list of languages, and a song with no such alias keeps its title exactly as given. Nothing is transliterated by machine: a made-up
/// spelling would be worse than the Latin one.
final class MusicNativeNames: @unchecked Sendable {
    static let shared = MusicNativeNames()

    /// Read by the views that draw a title, so they draw again when a native name arrives.
    @Observable final class Revision: @unchecked Sendable { var value = 0 }
    let revision = Revision()

    private let lock = NSLock()
    private var names: [String: String] = [:]     // request key -> native text
    private var asked: [String: Date] = [:]       // request key -> when it was last asked (a "no native name" answer is asked again after `retryAfter`)
    static let retryAfter: TimeInterval = 600
    static let capacity = 5000
    private var queue: [Request] = []
    private var running = false
    /// The languages the person's own listening shows (set by the home feed from their plays, never from a list): when a song's own language is not known, its names in these are used.
    private var preferred: Set<MusicLanguage> = []

    enum Kind: Sendable { case recording, person, album }
    struct Request: Sendable { var key: String; var kind: Kind; var uid: String?; var name: String; var track: MusicTrack? }

    /// The artist's name in the language and script they sing or work in, or nil (keep the name as given). `provider` is the source that gave the artist's id.
    func artist(_ ref: MusicArtistRef, provider: String) -> String? {
        ask(Request(key: "p|" + provider + "|" + (ref.id.isEmpty ? MusicText.normalize(ref.name) : ref.id), kind: .person, uid: ref.id.isEmpty ? nil : provider + ":" + ref.id, name: ref.name, track: nil))
    }

    func album(title: String, provider: String, id: String) -> String? {
        ask(Request(key: "a|" + provider + "|" + (id.isEmpty ? MusicText.normalize(title) : id), kind: .album, uid: id.isEmpty ? nil : provider + ":" + id, name: title, track: nil))
    }

    /// The artists of a track as one line, each in its own script where the graph knows it.
    func artistLine(of t: MusicTrack) -> String {
        t.artists.filter { !MusicArtistFiller.isFiller($0.name) }.map { artist($0, provider: t.providerID) ?? $0.name }.joined(separator: ", ")
    }

    private func ask(_ r: Request) -> String? {
        _ = revision.value
        guard MusicNativeNames.isLatin(r.name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let n = names[r.key] { return n }
        // The graph fills in while the person browses (an album opened, a completeness pass): an earlier "none" is asked again after a while.
        if asked[r.key].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true {
            if asked.count >= Self.capacity { asked.removeAll(); names.removeAll() }
            asked[r.key] = Date()
            queue.append(r)
            if !running { running = true; Task.detached(priority: .utility) { await MusicNativeNames.shared.drain() } }
        }
        return nil
    }

    /// The native title of the track, or nil. Also asks for it the first time a Latin title is seen.
    func title(for t: MusicTrack) -> String? {
        ask(Request(key: "t|" + t.uid, kind: .recording, uid: t.uid, name: t.title, track: t))
    }

    nonisolated static func isLatin(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { $0.value < 0x250 }
    }

    private func drain() async {
        while true {
            // `running` goes false in the same locked step that finds the line empty, so a request arriving now starts a new drain.
            let next: Request? = lock.withLock { () -> Request? in
                if queue.isEmpty { running = false; return nil }
                return queue.removeLast()   // the one asked for last is the one on screen now
            }
            guard let r = next else { return }
            let store = await MainActor.run { MusicEntityRuntime.shared.store.graph }
            let wanted = lock.withLock { preferred }
            if let n = await Self.lookup(r, store: store, preferred: wanted) {
                lock.withLock { names[r.key] = n }
                await MainActor.run { self.revision.value += 1 }
            }
        }
    }

    /// What the person's listening says about the languages they play. When it changes, the earlier "no native name" answers are asked again.
    func setPreferred(_ languages: Set<MusicLanguage>) {
        let languages = languages.subtracting([.latin])
        let changed = lock.withLock { () -> Bool in
            guard preferred != languages else { return false }
            preferred = languages; asked = [:]
            return true
        }
        if changed { Task { @MainActor in self.revision.value += 1 } }
    }

    /// The languages the person's listening shows, for pages that read names from the graph.
    var preferredLanguages: Set<MusicLanguage> { lock.withLock { preferred } }

    /// A graph entity's name as the page should draw it: in the script of a language the person listens to, or the entity's own language, when the graph holds
    /// that name (as the name itself or an alias); otherwise as stored. No language is named here: both sets come from data.
    nonisolated static func displayName(_ name: String, aliases: [String], entityLanguage: String?, preferred: Set<MusicLanguage>) -> String {
        var wanted = preferred
        if let own = entityLanguage.flatMap({ MusicLanguage(stated: $0) }), own != .latin { wanted.insert(own) }
        return pickPreferred(wanted, from: [name] + aliases) ?? name
    }

    /// Forgets every answer (Delete all music data).
    func reset() {
        lock.withLock { names = [:]; asked = [:]; queue = [] }
        revision.value += 1
    }

    static func lookup(_ r: Request, store: any MusicGraphStoring, preferred: Set<MusicLanguage> = []) async -> String? {
        switch r.kind {
        case .recording:
            guard let t = r.track else { return nil }
            let languages = await MusicGraphLanguage.languages(of: [t], store: store)
            let known = languages[t.uid] ?? MusicLanguageDetector.stated(t)
            // A song of a known non-Latin language is shown in that language's script. A song whose language is not known may still have names in a language the person listens to: those are used.
            if known == .latin || (known == nil && preferred.isEmpty) { return nil }
            let id = MusicEntityID.provisional(kind: .recording, providerUID: t.uid)
            let resolved = (try? await store.resolve(id)) ?? id
            var owners = [resolved]
            for e in ((try? await store.edges(of: resolved, predicate: .recordingOf, direction: .outgoing, limit: 2)) ?? []) { owners.append(e.object) }
            return await nativeText(of: owners, language: known, preferring: known == nil ? preferred : [], store: store)
        case .person, .album:
            let kind: MusicEntityKind = r.kind == .person ? .person : .release
            var owners: [MusicEntityID] = []
            if let uid = r.uid {
                let id = MusicEntityID.provisional(kind: kind, providerUID: uid)
                owners.append((try? await store.resolve(id)) ?? id)
            }
            if owners.isEmpty || r.kind == .person {
                // A name with no id of its own (or an id the graph has not met): the graph's person of the same romanised name.
                let kinds: Set<MusicEntityKind> = r.kind == .person ? [.person, .group] : [.release, .album]
                let want = MusicGraphText.latin(r.name)
                for h in ((try? await store.search(r.name, kinds: kinds, limit: 4)) ?? []) where MusicGraphText.latin(h.name) == want && !owners.contains(h.id) { owners.append(h.id) }
            }
            return await nativeText(of: owners, language: nil, store: store)
        }
    }

    /// The first non-Latin name or alias among the entities whose script is the wanted language's (the entity's own language when none was given).
    private static func nativeText(of owners: [MusicEntityID], language: MusicLanguage?, preferring: Set<MusicLanguage> = [], store: any MusicGraphStoring) async -> String? {
        for o in owners {
            guard let snap = try? await store.entity(o) else { continue }
            if language == nil, !preferring.isEmpty {
                // No language known for this song: any name of it in a language the person listens to.
                let aliases = ((try? await store.aliases(of: o)) ?? []).map(\.text)
                if let n = pickPreferred(preferring, from: [snap.name] + aliases) { return n }
                continue
            }
            let wanted = language?.script ?? snap.lang.flatMap { MusicLanguage(stated: $0) }?.script
            guard let wanted, wanted != .latin else { continue }
            if !isLatin(snap.name), MusicLanguageDetector.language(of: snap.name) == wanted { return snap.name }
            for a in ((try? await store.aliases(of: o)) ?? []) where !isLatin(a.text) {
                if MusicLanguageDetector.language(of: a.text) == wanted { return a.text }
            }
        }
        return nil
    }

    /// The first non-Latin name among these that is in one of the languages the person listens to (the names are in the order given). Pure.
    nonisolated static func pickPreferred(_ preferring: Set<MusicLanguage>, from names: [String]) -> String? {
        guard !preferring.isEmpty else { return nil }
        return names.first { !isLatin($0) && MusicLanguageDetector.language(of: $0).map { preferring.contains($0) } == true }
    }

    /// For tests: the pure pick of the alias for a language.
    nonisolated static func pick(language: MusicLanguage, from aliases: [String]) -> String? {
        aliases.first { !isLatin($0) && MusicLanguageDetector.language(of: $0) == language.script }
    }
}
