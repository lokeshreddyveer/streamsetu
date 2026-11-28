import SwiftUI

/// Music motion tokens. Durations are the provisional table from the design spec (80-500 ms); every animation a Music screen starts
/// comes from `MusicMotion.animation(_:reduce:)`, which returns nil (no animation) or a short fade when Reduce Motion is on.
///
/// Names (stable): `MusicMotion.Kind` (cases below), `MusicMotion.milliseconds(_:reduce:)`, `MusicMotion.seconds(_:reduce:)`,
/// `MusicMotion.animation(_:reduce:)`, `MusicMotion.transition(_:reduce:)`, `MusicMotion.Curve`, `MusicMotion.Spring`,
/// `MusicMotion.interruptible(_:reduce:)`, `MusicMotion.reduced` (the system and app Reduce Motion switch for non-View code).
enum MusicMotion {
    /// What is moving. Ordered by duration, shortest first.
    enum Kind: CaseIterable, Sendable {
        case press, hover, focus, toggle, tooltip, menu, fade, listChange, pageChange, panel, sheet, artwork, heroExpand

        /// Full-motion duration in milliseconds.
        var baseMilliseconds: Int {
            switch self {
            case .press: 80
            case .hover: 120
            case .focus: 140
            case .toggle: 160
            case .tooltip: 180
            case .menu: 200
            case .fade: 220
            case .listChange: 260
            case .pageChange: 300
            case .panel: 340
            case .sheet: 380
            case .artwork: 420
            case .heroExpand: 500
            }
        }

        /// Kinds that move or scale something; with Reduce Motion they become instant. The rest cross-fade briefly.
        var isSpatial: Bool {
            switch self {
            case .press, .hover, .focus, .toggle, .tooltip, .fade: false
            case .menu, .listChange, .pageChange, .panel, .sheet, .artwork, .heroExpand: true
            }
        }
    }

    /// Reduced-motion cross-fades never run longer than this.
    static let reducedFadeMilliseconds = 100

    /// A small set of curves (cubic Bezier control points).
    enum Curve: Sendable {
        /// Things entering or settling.
        case decelerate
        /// Things leaving.
        case accelerate
        /// Things moving between two resting places.
        case standard
        /// Large hero moves.
        case emphasized

        var points: (Double, Double, Double, Double) {
            switch self {
            case .decelerate: (0.0, 0.0, 0.2, 1.0)
            case .accelerate: (0.4, 0.0, 1.0, 1.0)
            case .standard: (0.4, 0.0, 0.2, 1.0)
            case .emphasized: (0.2, 0.0, 0.0, 1.0)
            }
        }

        func animation(seconds: Double) -> Animation {
            let p = points
            return .timingCurve(p.0, p.1, p.2, p.3, duration: seconds)
        }
    }

    /// A small set of springs. Springs keep velocity when interrupted, so they suit gestures and anything the user can reverse.
    enum Spring: Sendable {
        case snappy, smooth, gentle

        var animation: Animation {
            switch self {
            case .snappy: .spring(response: 0.28, dampingFraction: 0.9)
            case .smooth: .spring(response: 0.38, dampingFraction: 0.88)
            case .gentle: .spring(response: 0.55, dampingFraction: 0.92)
            }
        }
    }

    /// True when the person asked for less motion (the system switch or the app's own).
    static var reduced: Bool { BrandMotion.reduced(false) || MusicListeningModes.profile.reducesMotion }

    static func milliseconds(_ kind: Kind, reduce: Bool) -> Int {
        guard reduce else { return kind.baseMilliseconds }
        return kind.isSpatial ? 0 : min(kind.baseMilliseconds, reducedFadeMilliseconds)
    }

    static func seconds(_ kind: Kind, reduce: Bool) -> Double { Double(milliseconds(kind, reduce: reduce)) / 1000 }

    /// The animation for a kind. Nil means "do not animate" (Reduce Motion on a spatial change).
    static func animation(_ kind: Kind, reduce: Bool) -> Animation? {
        let ms = milliseconds(kind, reduce: reduce)
        if ms == 0 { return nil }
        if reduce { return .linear(duration: Double(ms) / 1000) }
        switch kind {
        case .press, .hover, .focus, .toggle, .tooltip: return Curve.standard.animation(seconds: Double(ms) / 1000)
        case .menu, .fade: return Curve.decelerate.animation(seconds: Double(ms) / 1000)
        case .listChange, .pageChange: return Curve.standard.animation(seconds: Double(ms) / 1000)
        case .panel, .sheet: return Spring.smooth.animation
        case .artwork: return Curve.emphasized.animation(seconds: Double(ms) / 1000)
        case .heroExpand: return Spring.gentle.animation
        }
    }

    /// A transition that scales or slides in full motion and is a plain fade under Reduce Motion.
    static func transition(_ full: AnyTransition, reduce: Bool) -> AnyTransition { reduce ? .opacity : full }

    /// For state a person can reverse mid-flight (scrub, drag, hover in/out, expand/collapse): a spring, so the new target starts from
    /// the current velocity; nil under Reduce Motion.
    static func interruptible(_ spring: Spring = .snappy, reduce: Bool) -> Animation? { reduce ? nil : spring.animation }
}

extension View {
    /// Animates `value` with a Music motion kind, honouring Reduce Motion (pass the environment's `accessibilityReduceMotion`).
    func musicAnimation<V: Equatable>(_ kind: MusicMotion.Kind, reduce: Bool, value: V) -> some View {
        animation(MusicMotion.animation(kind, reduce: reduce), value: value)
    }
}
