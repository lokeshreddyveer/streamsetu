import Foundation
import Accelerate
import NaturalLanguage

/// Step 7B: sentence vectors from Apple's on-device model. Optional: when the model is missing the engine runs on BM25 alone.
struct AtlasEmbeddings: Sendable {
    let dimension: Int
    private let vectors: [[Float]]   // L2-normalised, one per entry, empty when the entry could not be embedded

    /// Loaded once; the model object is only read after that.
    nonisolated(unsafe) static let sentence: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    nonisolated(unsafe) static let words: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)
    /// "sentence" when the sentence model is installed, "word-average" when only word vectors are (the sentence model was not available on the build machine), nil when neither.
    static var source: String? { sentence != nil ? "sentence" : words != nil ? "word-average" : nil }
    static func model() -> Bool { source != nil }

    /// A vector for a short text: the sentence model when present, else the mean of the word vectors of its words.
    static func vector(for text: String) -> [Double]? {
        if let s = sentence { return s.vector(for: text) }
        guard let w = words else { return nil }
        var sum: [Double] = [], n = 0
        for word in Normalise.words(text) where !Normalise.stopWords.contains(word) {
            guard let v = w.vector(for: word) else { continue }
            if sum.isEmpty { sum = v } else { for i in 0..<sum.count { sum[i] += v[i] } }
            n += 1
        }
        return n == 0 ? nil : sum
    }

    static func text(for e: AtlasEntry) -> String {
        let words = ([e.title, e.summary] + e.aliases).joined(separator: ". ").split(separator: " ").prefix(60)
        return words.joined(separator: " ")
    }

    /// Embeds every entry. Takes tens of milliseconds per hundred entries; call off the main thread.
    static func build(entries: [AtlasEntry]) -> AtlasEmbeddings? {
        guard model() else { return nil }
        let vs = entries.map { normalised(vector(for: text(for: $0))) }
        return AtlasEmbeddings(dimension: vs.first { !$0.isEmpty }?.count ?? 0, vectors: vs)
    }

    /// Entry indexes by cosine similarity to the query, best first.
    func rank(_ query: String, limit: Int) -> [(index: Int, score: Double)] {
        let q = Self.normalised(Self.vector(for: query))
        guard !q.isEmpty else { return [] }
        // One dot product per entry, done by Accelerate: the score is a pass over every entry, so a plain Swift loop here cost about 1.2 million
        // multiply-adds per query and, unoptimised (a debug build), was the whole query time. The values are the same cosine similarities.
        var out: [(Int, Double)] = []
        out.reserveCapacity(vectors.count)
        q.withUnsafeBufferPointer { qp in
            for (i, v) in vectors.enumerated() where v.count == q.count {
                var s: Float = 0
                v.withUnsafeBufferPointer { vp in vDSP_dotpr(qp.baseAddress!, 1, vp.baseAddress!, 1, &s, vDSP_Length(q.count)) }
                out.append((i, Double(s)))
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map { (index: $0.0, score: $0.1) }
    }

    private static func normalised(_ v: [Double]?) -> [Float] {
        guard let v, !v.isEmpty else { return [] }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard n > 0 else { return [] }
        return v.map { Float($0 / n) }
    }
}
