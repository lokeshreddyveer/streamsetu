import Foundation

/// A provider whose item replies carry credits. A mapper reads ONLY fields the reply holds: it makes no request and never infers a role.
protocol MusicProviderCreditSource {
    /// The `MusicProvider.id` of the provider (also the graph source id of its claims).
    static var sourceID: String { get }
    /// The credits and hints of one raw track object, nil when the reply carried none.
    static func trackBundle(_ raw: [String: Any]) -> MusicCreditBundle?
}

/// Collects credits in order and drops repeats (same person, role and level).
struct MusicCreditCollector {
    private(set) var credits: [MusicCredit] = []
    private var seen = Set<String>()

    /// Trims, drops empty names and the placeholders providers use for "nobody".
    static func cleanName(_ raw: String?) -> String? {
        guard var n = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}"))) else { return nil }
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let l = n.lowercased()
        if n.isEmpty || ["n/a", "na", "-", "--", "unknown", "unknown artist", "various", "various artists", "null", "none"].contains(l) { return nil }
        return n
    }

    /// The names of a flat "A, B; C" credit string. Duo names such as "Shankar-Jaikishan" stay whole: only commas, semicolons, slashes with spaces and "&" split.
    static func splitNames(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.replacingOccurrences(of: " & ", with: ",").replacingOccurrences(of: " / ", with: ",").replacingOccurrences(of: ";", with: ",")
            .split(separator: ",").compactMap { cleanName(String($0)) }
    }

    mutating func add(_ name: String?, role: MusicCreditRole, id: String? = nil, level: MusicCreditLevel = .track, instrument: String? = nil, character: String? = nil) {
        guard let n = Self.cleanName(name) else { return }
        let pid = id.flatMap { $0.isEmpty || $0 == n ? nil : $0 }
        let key = [pid ?? MusicGraphText.latin(n), role.rawValue, level.rawValue].joined(separator: "|")
        guard seen.insert(key).inserted else { return }
        credits.append(MusicCredit(name: n, role: role, providerArtistID: pid, level: level, instrument: instrument, character: character))
    }

    mutating func addNames(_ raw: String?, role: MusicCreditRole, level: MusicCreditLevel = .track) {
        for n in Self.splitNames(raw) { add(n, role: role, level: level) }
    }

    func bundle(hints: MusicProviderHints? = nil) -> MusicCreditBundle? {
        let h = (hints?.isEmpty ?? true) ? nil : hints
        return credits.isEmpty && h == nil ? nil : MusicCreditBundle(credits: credits, hints: h)
    }
}

extension MusicProviderHints {
    /// Four digits at the start of a date or a year field.
    static func year(_ s: String?) -> Int? {
        guard let s, s.count >= 4, let y = Int(s.prefix(4)), (1000...2999).contains(y) else { return nil }
        return y
    }
}
