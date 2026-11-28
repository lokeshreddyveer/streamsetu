import Foundation

/// What a chart is and where it came from. It lives in the model so every ranking can state its source, country and period; the page shows it only when the person opens the
/// chart's info (a control opened on purpose), never as a caption under the shelf.
struct MusicChartProvenance: Hashable, Sendable {
    var sourceName: String
    var region: String
    var period: String
    /// When this copy of the list was fetched; nil when it is not known.
    var fetchedAt: Date? = nil
}
