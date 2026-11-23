import Foundation

/// Loading a site, signing in, playing protected video and distribution are separate questions with separate answers.
enum Capability: String, CaseIterable, Sendable { case websiteLoading, authentication, protectedPlayback, distribution }

/// What can be said about one capability of a service on this platform. "Enabled for testing" never means "playback supported".
enum CapabilityStatus: String, Equatable, Sendable {
    case enabledForTesting, manualVerificationRequired, unavailable
    /// The owner checked it on his own Mac (Netflix only today); never set by an automated test.
    case ownerVerified
    /// Known not to work in an embedded view.
    case unsupported
    /// Reserved; unused.
    case notPermitted
}

/// Informational evidence note shown in Settings. The decision field is `ProviderDefinition.distributionAuthorization`.
enum DistributionStatus: String, Equatable, Sendable { case unverified, authorised }

enum Evidence: String, Sendable { case ownerCheck, vendorTerms, vendorHelp, researchSnippet, none }

struct CapabilityRecord<S: Equatable & Sendable>: Equatable, Sendable {
    var status: S
    var evidence: Evidence
    var noteKey: String?
    init(_ status: S, evidence: Evidence = .none, noteKey: String? = nil) { self.status = status; self.evidence = evidence; self.noteKey = noteKey }
}

/// The original three-field profile, kept so existing callers and tests keep working.
struct ServiceCapabilityProfile: Equatable, Sendable {
    var websiteLoading: CapabilityStatus
    var signIn: CapabilityStatus
    var protectedPlayback: CapabilityStatus
}

struct CapabilityMatrix: Equatable, Sendable {
    var websiteLoading: CapabilityRecord<CapabilityStatus>
    var authentication: CapabilityRecord<CapabilityStatus>
    var protectedPlayback: CapabilityRecord<CapabilityStatus>
    var distribution: CapabilityRecord<DistributionStatus>
    var compatibility: CompatibilityResult = .unchecked

    /// The frozen three-field view. It never claims more than "enabled for testing" or "needs a manual check", whatever the matrix says.
    var legacyProfile: ServiceCapabilityProfile {
        func manual(_ s: CapabilityStatus) -> CapabilityStatus {
            switch s {
            case .unavailable, .unsupported, .notPermitted: s
            default: .manualVerificationRequired
            }
        }
        let loading: CapabilityStatus = websiteLoading.status == .unavailable ? .unavailable : .enabledForTesting
        return ServiceCapabilityProfile(websiteLoading: loading, signIn: manual(authentication.status), protectedPlayback: manual(protectedPlayback.status))
    }
}
