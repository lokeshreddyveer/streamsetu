import Foundation

/// Reciprocal Rank Fusion: score(d) = sum over rankers of weight / (k + rank).
enum Fusion {
    static let k = 60.0
    /// Chosen on the question bank (the weight grid in AtlasBankTests' report): with only word-vector averages available on the build machine every weight above 0 lowered MRR@10, so the
    /// default is BM25 alone. Re-run the grid when the sentence model is installed. BM25 weight is always 1.
    static let embeddingWeight = 0.0

    static func rrf(_ lists: [(ranking: [Int], weight: Double)]) -> [(index: Int, score: Double)] {
        var s: [Int: Double] = [:]
        for l in lists { for (r, d) in l.ranking.enumerated() { s[d, default: 0] += l.weight / (k + Double(r + 1)) } }
        return s.map { (index: $0.key, score: $0.value) }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    }
}
