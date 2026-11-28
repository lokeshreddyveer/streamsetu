import Foundation
import Observation

/// A thin adapter over the app's `ToastCenter`: Music's timings (2.5 s, 8 s with an action) and its friendly error wording, in one place.
@MainActor @Observable
final class MusicToasts {
    static let shared = MusicToasts()

    enum Kind: Sendable { case info, success, error }

    nonisolated static let plainSeconds: Double = 2.5
    nonisolated static let actionSeconds: Double = 8

    /// How long a toast stays. An error is not special: it times out like any other.
    nonisolated static func duration(hasAction: Bool) -> Double { hasAction ? actionSeconds : plainSeconds }

    @ObservationIgnored private(set) var center: ToastCenter?

    /// Called by the Music main view with the app's centre.
    func bind(_ center: ToastCenter?) { if let center { self.center = center } }

    func show(_ text: String, kind: Kind = .info, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        guard let center else { return }
        if kind != .error, MusicListeningModes.profile.quietToasts { return }
        let symbol: String, k: Toast.Kind
        switch kind {
        case .info: symbol = "info.circle.fill"; k = .info
        case .success: symbol = "checkmark.circle.fill"; k = .success
        case .error: symbol = "exclamationmark.triangle.fill"; k = .error
        }
        center.show(MusicFriendlyErrors.rewrite(text), symbol: symbol, kind: k, duration: Self.duration(hasAction: action != nil),
                    actionTitle: actionTitle, action: action)
    }

    func success(_ text: String) { show(text, kind: .success) }
    func error(_ error: Error) { show(MusicFriendlyErrors.message(for: error), kind: .error) }
    func error(_ text: String) { show(text, kind: .error) }
}
