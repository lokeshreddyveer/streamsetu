import Foundation

// A specialised layer for Indian art music (Carnatic and Hindustani): the raga, tala, form and composition that a curated dataset documents for a recording. It
// reuses the app's own ids: a recording is linked to a song only through its MusicBrainz recording id, never by title. The names come from the dataset's own
// annotation and are never guessed, translated or filled in; an algorithmic prediction is a different kind of record and never appears with documented ones.
// Every record keeps its dataset, its version and its rights, because a dataset's licence travels with its data.

enum ClassicalTradition: String, Codable, Sendable, CaseIterable { case carnatic, hindustani }

/// How an annotation came to be. Only `documented` is ever listed with facts; `predicted` (for example a raga-recognition model's guess) is kept apart.
enum ClassicalAnnotationKind: String, Codable, Sendable { case documented, predicted }

struct ClassicalName: Codable, Hashable, Sendable {
    var id: String?          // the dataset's own uuid for the raga or tala
    var name: String
    var aliases: [String]    // common name and transliteration, as the dataset gives them
}

struct ClassicalPerson: Codable, Hashable, Sendable {
    var mbid: String?
    var name: String
    var instrument: String?
}

struct ClassicalDataset: Codable, Hashable, Sendable {
    var name: String         // "Saraga"
    var version: String      // "1.5"
    var rights: String       // the dataset's licence as it states it
}

struct ClassicalRecording: Codable, Hashable, Sendable, Identifiable {
    var mbid: String?        // MusicBrainz recording id of the track
    var title: String
    var tradition: ClassicalTradition
    var ragas: [ClassicalName]
    var talas: [ClassicalName]
    var forms: [String]
    var workTitle: String?
    var workMBID: String?
    var artists: [ClassicalPerson]
    var concert: String?
    var dataset: ClassicalDataset
    var kind: ClassicalAnnotationKind = .documented

    var id: String { (mbid ?? "title:" + MusicText.normalize(title)) + "|" + tradition.rawValue }
    var isVerified: Bool { kind == .documented }
}

enum SaragaMetadataParser {
    private static func text(_ any: Any?) -> String? {
        if let s = any as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        return nil
    }

    private static func list(_ any: Any?) -> [[String: Any]] {
        if let a = any as? [[String: Any]] { return a }
        if let o = any as? [String: Any] { return [o] }
        return []
    }

    private static func names(_ any: Any?) -> [ClassicalName] {
        list(any).compactMap { d in
            let primary = text(d["name"]) ?? text(d["common_name"]) ?? text(d["transliteration"])
            guard let name = primary else { return nil }
            var aliases: [String] = []
            for key in ["common_name", "transliteration"] { if let a = text(d[key]), a != name, !aliases.contains(a) { aliases.append(a) } }
            return ClassicalName(id: text(d["uuid"]) ?? text(d["id"]), name: name, aliases: aliases)
        }
    }

    private static func people(_ any: Any?) -> [ClassicalPerson] {
        list(any).compactMap { d in
            // Artist entries nest the person ("artist": {...}) with an "instrument" beside it; album artists are flat.
            let inner = d["artist"] as? [String: Any] ?? d
            guard let name = text(inner["name"]) else { return nil }
            return ClassicalPerson(mbid: text(inner["mbid"]), name: name, instrument: text((d["instrument"] as? [String: Any])?["name"]) ?? text(d["instrument"]))
        }
    }

    /// One metadata file. Carnatic files use raaga/taala/form/work/concert, Hindustani files raags/taals/forms/works/release; the tradition says which. A file with
    /// no title is not a recording record and is skipped.
    static func parse(_ data: Data, tradition: ClassicalTradition, dataset: ClassicalDataset) -> ClassicalRecording? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let title = text(j["title"]) else { return nil }
        let hasAnnotation = ["raaga", "taala", "raags", "taals", "form", "forms", "work", "works"].contains { j[$0] != nil }
        guard hasAnnotation else { return nil }
        let work = list(j["work"] ?? j["works"]).first
        let formNames = names(j["form"] ?? j["forms"]).map(\.name)
        let concert = list(j["concert"] ?? j["release"]).first.flatMap { text($0["title"]) ?? text($0["name"]) }
        return ClassicalRecording(
            mbid: text(j["mbid"]), title: title, tradition: tradition,
            ragas: names(j["raaga"] ?? j["raags"]), talas: names(j["taala"] ?? j["taals"]), forms: formNames,
            workTitle: work.flatMap { text($0["title"]) }, workMBID: work.flatMap { text($0["mbid"]) },
            artists: people(j["artists"]) + people(j["album_artists"]),
            concert: concert, dataset: dataset)
    }
}

struct ClassicalRagaEntry: Hashable, Sendable, Identifiable {
    var key: String
    var name: String
    var aliases: [String]
    var tradition: ClassicalTradition
    var recordings: [ClassicalRecording]
    var id: String { tradition.rawValue + "|" + key }
}

struct ClassicalIndex: Codable, Sendable, Equatable {
    var recordings: [ClassicalRecording] = []
    var builtAt: Date = Date()

    /// A recording the dataset documents for this MusicBrainz recording id, if any. The only way a song gets a raga from this layer.
    func recording(mbid: String) -> ClassicalRecording? {
        let key = mbid.lowercased()
        return recordings.first { $0.mbid?.lowercased() == key && $0.isVerified }
    }

    static func key(_ s: String) -> String { MusicText.normalize(s) }

    /// Ragas with the recordings that document them, most recordings first. Predicted annotations are never listed.
    func ragas(tradition: ClassicalTradition? = nil) -> [ClassicalRagaEntry] {
        var by: [String: ClassicalRagaEntry] = [:]
        for r in recordings where r.isVerified && (tradition == nil || r.tradition == tradition) {
            for n in r.ragas {
                let id = r.tradition.rawValue + "|" + Self.key(n.name)
                var e = by[id] ?? ClassicalRagaEntry(key: Self.key(n.name), name: n.name, aliases: [], tradition: r.tradition, recordings: [])
                for a in n.aliases where !e.aliases.contains(a) && Self.key(a) != e.key { e.aliases.append(a) }
                if !e.recordings.contains(where: { $0.id == r.id }) { e.recordings.append(r) }
                by[id] = e
            }
        }
        return by.values.sorted { $0.recordings.count != $1.recordings.count ? $0.recordings.count > $1.recordings.count : $0.name < $1.name }
    }

    /// Talas with the recordings that document them, in the same shape as ragas.
    func talas(tradition: ClassicalTradition? = nil) -> [ClassicalRagaEntry] {
        var by: [String: ClassicalRagaEntry] = [:]
        for r in recordings where r.isVerified && (tradition == nil || r.tradition == tradition) {
            for n in r.talas {
                let id = r.tradition.rawValue + "|" + Self.key(n.name)
                var e = by[id] ?? ClassicalRagaEntry(key: Self.key(n.name), name: n.name, aliases: [], tradition: r.tradition, recordings: [])
                for a in n.aliases where !e.aliases.contains(a) && Self.key(a) != e.key { e.aliases.append(a) }
                if !e.recordings.contains(where: { $0.id == r.id }) { e.recordings.append(r) }
                by[id] = e
            }
        }
        return by.values.sorted { $0.recordings.count != $1.recordings.count ? $0.recordings.count > $1.recordings.count : $0.name < $1.name }
    }

    func search(_ query: String, talas wantTalas: Bool = false) -> [ClassicalRagaEntry] {
        let q = Self.key(query)
        let all = wantTalas ? talas() : ragas()
        guard !q.isEmpty else { return all }
        return all.filter { e in e.key.contains(q) || e.aliases.contains { Self.key($0).contains(q) } }
    }
}
