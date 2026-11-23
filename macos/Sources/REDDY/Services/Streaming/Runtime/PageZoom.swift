import Foundation

/// The size of a service's page, as WebKit's own page zoom (never a script). Kept for the app, not tied to the site's data.
/// Each service names its own baseline and defaults key (from its definition); the unlabelled initialisers keep the original values.
struct PageZoom: Equatable {
    static let range = 0.6...1.5
    static let step = 0.05
    /// The original values (the first service's), used where no definition is given.
    static let defaultValue = 0.85
    static let defaultsKey = "netflix.pageZoom"

    let baseline: Double
    let storageKey: String
    private(set) var value: Double

    static func clamp(_ v: Double, fallback: Double = PageZoom.defaultValue) -> Double {
        guard v.isFinite else { return fallback }
        let c = min(range.upperBound, max(range.lowerBound, v))
        return (c * 20).rounded() / 20          // always on a 5% step
    }

    init(_ v: Double = PageZoom.defaultValue, baseline: Double = PageZoom.defaultValue, storageKey: String = PageZoom.defaultsKey) {
        self.baseline = Self.clamp(baseline); self.storageKey = storageKey; value = Self.clamp(v, fallback: baseline)
    }

    /// Reads what was saved; nothing, or nonsense, gives the baseline.
    init(defaults: UserDefaults, baseline: Double = PageZoom.defaultValue, storageKey: String = PageZoom.defaultsKey) {
        self.init(defaults.object(forKey: storageKey) as? Double ?? baseline, baseline: baseline, storageKey: storageKey)
    }

    mutating func zoomIn() { value = Self.clamp(value + Self.step, fallback: baseline) }
    mutating func zoomOut() { value = Self.clamp(value - Self.step, fallback: baseline) }
    mutating func reset() { value = baseline }
    var canZoomIn: Bool { value < Self.range.upperBound - 0.0001 }
    var canZoomOut: Bool { value > Self.range.lowerBound + 0.0001 }
    var isDefault: Bool { abs(value - baseline) < 0.0001 }
    var percent: Int { Int((value * 100).rounded()) }

    func save(to defaults: UserDefaults) { defaults.set(value, forKey: storageKey) }
}
