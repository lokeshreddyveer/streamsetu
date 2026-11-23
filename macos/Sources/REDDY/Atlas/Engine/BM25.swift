import Foundation

/// Step 7A: BM25F over the atlas fields. Documents are tokenised and stemmed once; the query is the part that gets corrected and expanded.
struct BM25Index: Sendable {
    struct Field: Sendable { let weight: Double; let text: @Sendable (AtlasEntry) -> String }
    static let k1 = 1.2, b = 0.75
    static let fields: [Field] = [
        Field(weight: 4) { $0.title }, Field(weight: 4) { $0.aliases.joined(separator: " ") }, Field(weight: 2) { $0.path.joined(separator: " ") },
        Field(weight: 1.5) { $0.summary }, Field(weight: 1) { $0.detail ?? "" }, Field(weight: 2) { $0.value?.options.joined(separator: " ") ?? "" },
        Field(weight: 1) { String($0.id.drop(while: { $0 != "." }).dropFirst()).replacingOccurrences(of: ".", with: " ").splitCamel() },
    ]

    let count: Int
    private let postings: [String: [(doc: Int32, tf: Float)]]
    /// Every unstemmed word of every document, with the number of entries holding it.
    let vocabulary: [String: Int]

    init(entries: [AtlasEntry]) {
        count = entries.count
        var vocab: [String: Int] = [:]
        // Pass 1: tokens per field per document, and average field lengths.
        var toks: [[[String]]] = []
        var totals = [Double](repeating: 0, count: Self.fields.count)
        for e in entries {
            var perField: [[String]] = []
            var seen = Set<String>()
            for (fi, f) in Self.fields.enumerated() {
                let words = Normalise.words(f.text(e))
                for w in words where seen.insert(w).inserted { vocab[w, default: 0] += 1 }
                let t = words.filter { !Normalise.stopWords.contains($0) }.map(Normalise.stem)
                totals[fi] += Double(t.count)
                perField.append(t)
            }
            toks.append(perField)
        }
        let avg = totals.map { max($0 / Double(max(entries.count, 1)), 1) }
        var post: [String: [(doc: Int32, tf: Float)]] = [:]
        for (di, perField) in toks.enumerated() {
            var acc: [String: Double] = [:]
            for (fi, t) in perField.enumerated() {
                let norm = 1 - Self.b + Self.b * Double(t.count) / avg[fi]
                for w in t { acc[w, default: 0] += Self.fields[fi].weight / norm }
            }
            for (w, v) in acc { post[w, default: []].append((Int32(di), Float(v))) }
        }
        postings = post
        vocabulary = vocab
    }

    func idf(_ term: String) -> Double {
        let n = Double(postings[term]?.count ?? 0)
        return log(1 + (Double(count) - n + 0.5) / (n + 0.5))
    }

    /// Score per document for weighted query terms (already stemmed). Documents with no matching term are absent.
    func score(_ terms: [(term: String, weight: Double)]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for (t, qw) in terms {
            guard let p = postings[t] else { continue }
            let i = idf(t)
            for (d, tf) in p { out[Int(d), default: 0] += qw * i * Double(tf) / (Self.k1 + Double(tf)) }
        }
        return out
    }
}

extension String {
    /// "hardwareDecoding" -> "hardware Decoding"
    func splitCamel() -> String {
        var out = ""
        for c in self { if c.isUppercase, !out.isEmpty { out.append(" ") }; out.append(c) }
        return out
    }
}
