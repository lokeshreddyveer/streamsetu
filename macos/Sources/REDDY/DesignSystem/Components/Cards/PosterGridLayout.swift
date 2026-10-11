import CoreGraphics

/// Column maths for poster grids: as many columns as fit, cards share the leftover width evenly.
enum PosterGridLayout {
    struct Result: Equatable { let columns: Int; let cardWidth: CGFloat }

    static func compute(available: CGFloat, minCard: CGFloat = 140, maxCard: CGFloat = 190, gap: CGFloat = 12) -> Result {
        guard available > 0 else { return Result(columns: 1, cardWidth: minCard) }
        var n = max(1, Int(((available + gap) / (minCard + gap)).rounded(.down)))
        var w = (available - gap * CGFloat(n - 1)) / CGFloat(n)
        while w > maxCard, n < 24 { n += 1; w = (available - gap * CGFloat(n - 1)) / CGFloat(n) }   // very wide windows: more columns, not giant posters
        return Result(columns: n, cardWidth: max(1, w.rounded(.down)))
    }
}
