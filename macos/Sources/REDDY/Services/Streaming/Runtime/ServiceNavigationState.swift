import Foundation
import Observation

/// What the person sees of one service's page: loading, ready, failed, stopped, plus the notices. No WebKit, so it is plain data a view reads
/// and a test can drive. Page-state persistence (`lastURL`, `pendingURL`) is kept here, apart from the session (which lives in the data store).
@MainActor @Observable
final class ServiceNavigationState {
    enum Phase: Equatable { case idle, loading, ready, failed(ServiceFailure), terminated }
    enum Notice: Equatable { case downloadBlocked }

    var phase: Phase = .idle
    var isSlow = false
    var canGoBack = false
    var canGoForward = false
    var notice: Notice?
    /// An address outside the site that the page asked to open, held until the person answers (services that confirm only).
    var pendingExternal: URL?
    /// The host (or kind) of an off-site link that was cancelled with a notice (services that never leave the app).
    var blockedLinkHost: String?
    var lastStatusCode: Int?
    /// A page has been shown since the web view was made.
    var hasContent = false
    /// Whether the service's store holds a cookie for the site's own domain (a yes or no, never names or values).
    var hasSession = false
    /// Counts web views made, so a view that hosts the web view can notice a new one.
    var webViewGeneration = 0
    @ObservationIgnored var lastURL: URL?
    @ObservationIgnored var pendingURL: URL?

    /// Back to what a fresh web view starts from (the last address is kept).
    func resetForReleasedView() {
        isSlow = false; phase = .idle; canGoBack = false; canGoForward = false; hasContent = false
    }
}
