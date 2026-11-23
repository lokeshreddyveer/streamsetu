import Foundation

/// What the native error screen of one service offers, from its definition. A service that confirms external links keeps its browser button;
/// every other service offers Retry and Return to StreamSetu only (no browser fallback, no redirect).
struct ServiceFailureScreen: Equatable {
    enum Action: Equatable { case retry, openInDefaultBrowser, returnToStreamSetu }
    enum Reason: Equatable { case failed(ServiceFailure), terminated }

    let serviceName: String
    let reason: Reason
    let actions: [Action]

    init?(phase: ServiceNavigationState.Phase, definition: ProviderDefinition) {
        switch phase {
        case .failed(let f): reason = .failed(f)
        case .terminated: reason = .terminated
        default: return nil
        }
        serviceName = definition.displayName
        if case .failed(.regionRestricted) = phase { actions = [.retry, .returnToStreamSetu]; return }          // never a browser fallback: the provider decided
        switch definition.externalLinks {
        case .confirmThenOpen: actions = [.retry, .openInDefaultBrowser]
        case .blockWithNotice: actions = [.retry, .returnToStreamSetu]
        }
    }
}
