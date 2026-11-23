import Foundation

/// One title's identity, derived from what the playlist says about it. The same film in another playlist, another language or another quality derives the same `key`.
/// Nothing is stored on the playlist rows: this is a pure function of the title, its folder's name and its year.
struct DerivedIdentity: Equatable, Sendable {
    var key: String
    var year: Int?
    /// The language in English ("Hindi"), or nil when neither the title nor the folder says one.
    var language: String?
    var qualityRank: Int
    var isCam: Bool
    /// Kind and normalized folder name: folders with the same key in different playlists are one family (see FolderFamily).
    var folderKey: String?
}

/// IdentityKey v1: the frozen matching rule behind "the same title". It is the rule the "Other languages" row already uses (year, quality words, language words,
/// "and" and a leading article removed), with two changes that make it stable: no locale is read, and the word lists live here and are versioned, so a change to
/// them is a new version (`IdentityKey.version`) and the stored keys are re-derived in the background, never silently mixed.
enum IdentityKey {
    static let version = 1

    private static let articles: Set<String> = ["the", "a", "an"]
    private static let noise = TitleVocabulary.identityNoise
    /// The words a title or folder uses for a language, with the name shown for it (the identity rule's frozen subset of TitleVocabulary).
    static let languageNames: [String: String] = TitleVocabulary.languageNames.filter { TitleVocabulary.identityLanguageWords.contains($0.key) }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lower case, accents removed, every other character that is not a letter or digit a space; split into words.
    static func words(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posix).lowercased(with: posix)
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").map(String.init)
    }

    private static func isYear(_ w: String) -> Bool { w.count == 4 && w.allSatisfy(\.isNumber) && (w.hasPrefix("19") || w.hasPrefix("20")) }

    static func make(_ title: String) -> String {
        let all = words(title)
        var w = all.filter { !isYear($0) && !noise.contains($0) && languageNames[$0] == nil && $0 != "and" }
        if let first = w.first, articles.contains(first), w.count > 1 { w.removeFirst() }
        // A title made only of such words ("HD", "English") keeps them rather than collapse to nothing.
        return w.isEmpty ? all.joined(separator: " ") : w.joined(separator: " ")
    }
}

enum IdentityDerive {
    private static let tagPattern = try! NSRegularExpression(pattern: #"[\(\[]\s*([A-Za-z]+)\s*[\)\]]"#)
    /// A 19xx or 20xx written in a title; the one pattern every year-in-title reader uses.
    static let yearInTitle = try! NSRegularExpression(pattern: #"(?<![0-9])((?:19|20)[0-9]{2})(?![0-9])"#)
    private static let cinemaCopy = try! NSRegularExpression(pattern: #"\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine)\b"#, options: .caseInsensitive)
    private static let subtitleWords: Set<String> = ["subtitles", "subtitle", "subs", "sub", "subbed"]

    /// A folder or title names a language: a "(Lang)" tag in the title, a dub named by the folder, the first language word of the folder that is not a subtitle language, then a language word in the title.
    static func language(title: String, folder: String?) -> String? {
        for m in tagPattern.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
            if let r = Range(m.range(at: 1), in: title), let name = IdentityKey.languageNames[title[r].lowercased()] { return name }
        }
        let f = folder.map(IdentityKey.words) ?? []
        for (i, w) in f.enumerated() where w == "dubbed" {
            if i > 0, let name = IdentityKey.languageNames[f[i - 1]] { return name }
            if i + 2 < f.count, f[i + 1] == "in", let name = IdentityKey.languageNames[f[i + 2]] { return name }
        }
        for (i, w) in f.enumerated() {
            guard let name = IdentityKey.languageNames[w] else { continue }
            if i + 1 < f.count, subtitleWords.contains(f[i + 1]) { continue }
            return name
        }
        return IdentityKey.words(title).lazy.compactMap { IdentityKey.languageNames[$0] }.first
    }

    /// 4K 5, FHD 4, HD 3, unmarked 2, SD 1, a cinema recording 0 (one vocabulary for ranking copies).
    static func quality(title: String, folder: String?) -> (rank: Int, isCam: Bool) {
        let text = [title, folder].compactMap { $0 }.joined(separator: " ")
        if cinemaCopy.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return (0, true) }
        switch MetadataNormalizer.qualityLabel(MetadataNormalizer.normalize(title)) {
        case "4K": return (5, false)
        case "FHD": return (4, false)
        case "HD": return (3, false)
        case "SD": return (1, false)
        default: return (2, false)
        }
    }

    static func year(_ declared: Int?, title: String) -> Int? {
        if let y = declared, y > 0 { return y }
        guard let m = yearInTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let r = Range(m.range(at: 1), in: title) else { return nil }
        return Int(title[r])
    }

    static func derive(title: String, categoryName: String?, year: Int?, kind: ContentKind) -> DerivedIdentity {
        let q = quality(title: title, folder: categoryName)
        let folderWords = categoryName.map { IdentityKey.words($0).joined(separator: " ") } ?? ""
        return DerivedIdentity(key: IdentityKey.make(title), year: Self.year(year, title: title), language: language(title: title, folder: categoryName),
                               qualityRank: q.rank, isCam: q.isCam, folderKey: folderWords.isEmpty ? nil : "\(kind.rawValue)|\(folderWords)")
    }

    /// FNV-1a 64 of what identity was derived from: when it is the same, the row is not derived again on a sync.
    static func inputHash(title: String, categoryName: String?, year: Int?) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(title)|\(categoryName ?? "")|\(year.map(String.init) ?? "")".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int64(bitPattern: h)
    }
}

/// What a sync changed for one playlist and kind, as far as identity is concerned. Large changes are only counted (`bulk`): the caller then rebuilds instead of patching.
struct IdentityChangeSet: Equatable, Sendable {
    static let cap = 5000
    let sourceID: UUID
    let kind: ContentKind
    private(set) var addedIDs: [String] = []
    private(set) var changedIDs: [String] = []
    private(set) var removedIDs: [String] = []
    private(set) var addedCount = 0, changedCount = 0, removedCount = 0
    var bulk: Bool { addedCount > Self.cap || changedCount > Self.cap || removedCount > Self.cap }
    var isEmpty: Bool { addedCount + changedCount + removedCount == 0 }

    init(sourceID: UUID, kind: ContentKind) { self.sourceID = sourceID; self.kind = kind }
    mutating func added(_ id: String) { addedCount += 1; if addedIDs.count < Self.cap { addedIDs.append(id) } }
    mutating func changed(_ id: String) { changedCount += 1; if changedIDs.count < Self.cap { changedIDs.append(id) } }
    mutating func removed(_ id: String) { removedCount += 1; if removedIDs.count < Self.cap { removedIDs.append(id) } }
}
