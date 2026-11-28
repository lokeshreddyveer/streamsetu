import Foundation

/// Step 5: words and phrases that mean something else in this app. The query is expanded, never the documents. Keys are lowercase words as typed; values are words to add.
enum Synonyms {
    static let table: [(key: [String], adds: [String])] = [
        (["kill", "switch"], ["vpn", "pause"]), (["subs"], ["subtitle"]), (["sub"], ["subtitle"]), (["cc"], ["subtitle"]), (["captions"], ["subtitle"]), (["caption"], ["subtitle"]),
        (["dns"], ["dns", "secure"]), (["cmd"], ["command"]), (["fav"], ["favorite"]), (["favs"], ["favorite"]), (["favourite"], ["favorite"]), (["favourites"], ["favorite"]),
        (["telly"], ["tv"]), (["epg"], ["guide", "programme"]), (["program"], ["programme"]), (["programs"], ["programme"]),
        (["hw"], ["hardware"]), (["gpu"], ["hardware"]), (["acceleration"], ["decoding"]), (["tonite"], ["tonight"]), (["hearted"], ["favorite"]), (["hearts"], ["favorite"]), (["heart"], ["favorite"]),
        (["colour"], ["color"]), (["colours"], ["color"]), (["dark", "mode"], ["theme"]), (["light", "mode"], ["theme"]), (["night", "mode"], ["volume", "normalization"]),
        (["loud"], ["volume"]), (["quiet"], ["volume"]), (["louder"], ["volume"]), (["sound"], ["audio"]), (["lag"], ["buffering"]), (["lags"], ["buffering"]), (["stutter"], ["buffering"]),
        (["stutters"], ["buffering"]), (["freeze"], ["buffering"]), (["freezes"], ["buffering"]), (["freezing"], ["buffering"]), (["laggy"], ["buffering"]), (["choppy"], ["buffering"]),
        (["xstream"], ["xtream"]), (["xtreme"], ["xtream"]), (["iptv"], ["playlist"]), (["provider"], ["playlist", "source"]), (["m3u8"], ["m3u"]),
        (["icloud"], ["icloud", "sync"]), (["sync"], ["icloud"]), (["backup"], ["backup", "export"]), (["restore"], ["backup"]),
        (["binge"], ["autoplay", "next", "episode"]), (["autoplay"], ["next", "episode"]), (["skip", "intro"], ["next", "episode"]),
        (["kids"], ["parental", "profile"]), (["child"], ["parental", "profile"]), (["children"], ["parental", "profile"]), (["wife"], ["profile"]), (["husband"], ["profile"]), (["pin"], ["parental"]),
        (["touch", "id"], ["app", "lock"]), (["aplock"], ["app", "lock"]), (["passcode"], ["app", "lock"]), (["face", "id"], ["app", "lock"]),
        (["animation"], ["motion"]), (["animations"], ["motion"]), (["bigger"], ["size"]), (["smaller"], ["size"]), (["large"], ["size"]), (["font"], ["size"]),
        (["hotkey"], ["shortcut", "keyboard"]), (["hotkeys"], ["shortcut", "keyboard"]), (["keys"], ["keyboard"]),
        (["record"], ["recording"]), (["dvr"], ["recording"]), (["offline"], ["download"]), (["save"], ["download"]),
        (["mkv"], ["engine", "mpv"]), (["codec"], ["engine"]), (["player"], ["engine"]), (["hdr"], ["tone", "mapping"]), (["interlaced"], ["deinterlace"]),
        (["resume"], ["resume", "position"]), (["continue"], ["resume", "position"]), (["whered"], ["resume"]), (["stopped"], ["resume"]),
        (["refresh"], ["refresh", "update"]), (["update"], ["refresh"]), (["reload"], ["refresh"]),
        (["mute"], ["volume"]), (["dub"], ["audio", "language"]), (["dubbed"], ["audio", "language"]),
        (["wrong", "artwork"], ["artwork", "tmdb"]), (["posters"], ["artwork", "tmdb"]), (["poster"], ["artwork", "tmdb"]), (["cast"], ["cast", "director"]),
        (["slow"], ["buffering"]), (["pixelated"], ["quality"]), (["blurry"], ["quality"]), (["sharp"], ["quality"]), (["resolution"], ["quality"]),
        (["reminders"], ["reminder"]), (["notification"], ["reminder"]), (["notifications"], ["reminder"]), (["alert"], ["reminder", "alert"]),
        (["channel", "list"], ["channel", "manager"]),
        // Hinglish and Telugu in Latin letters for topic words (question words are in Normalise.stopWords and IntentDetector).
        (["awaaz"], ["audio", "volume"]), (["avaz"], ["audio", "volume"]), (["gaana"], ["song", "music"]), (["gaane"], ["song", "music"]), (["paata"], ["song", "music"]), (["patalu"], ["song", "music"]),
        (["bada"], ["size"]), (["chota"], ["size"]), (["chhota"], ["size"]), (["bhasha"], ["language"]), (["basha"], ["language"]), (["bhaasha"], ["language"]),
        (["chalu"], ["on", "start"]), (["sleap"], ["sleep"]), (["slep"], ["sleep"]), (["crosfade"], ["crossfade"]), (["manage", "channels"], ["channel", "manager"]),
    ]

    private static let index: [String: [Int]] = {
        var m: [String: [Int]] = [:]
        for (i, row) in table.enumerated() { m[row.key[0], default: []].append(i) }
        return m
    }()

    /// All words in the table's keys, so the spell corrector leaves them alone.
    static let keyWords: Set<String> = Set(table.flatMap(\.key))

    /// Extra words the query should also match, found by scanning for each key phrase.
    static func expansions(for words: [String]) -> [String] {
        var out: [String] = []
        for (i, w) in words.enumerated() {
            for r in index[w] ?? [] {
                let key = table[r].key
                if i + key.count <= words.count, Array(words[i..<(i + key.count)]) == key { out.append(contentsOf: table[r].adds) }
            }
        }
        return out
    }

    /// Cycle check used by tests: no key phrase may be produced solely by expanding another key phrase back to itself in a loop.
    static func hasCycle() -> Bool {
        let keys = Set(table.map { $0.key.joined(separator: " ") })
        var graph: [String: Set<String>] = [:]
        for row in table where row.adds.count == 1 && keys.contains(row.adds[0]) && row.key.count == 1 { graph[row.key[0], default: []].insert(row.adds[0]) }
        func reaches(_ a: String, _ target: String, _ seen: inout Set<String>) -> Bool {
            for n in graph[a] ?? [] { if n == target { return true }; if seen.insert(n).inserted, reaches(n, target, &seen) { return true } }
            return false
        }
        return graph.keys.contains { var s = Set<String>(); return reaches($0, $0, &s) }
    }
}
