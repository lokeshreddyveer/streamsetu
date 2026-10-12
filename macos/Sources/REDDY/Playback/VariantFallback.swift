import Foundation

/// Picks the next quality copy of a channel to try when the one playing has failed for good. A channel listed as HD, FHD and 4K
/// has three streams; if one is down another often works. Pure, so the order and the "never twice" rule are testable.
enum VariantFallback {
    /// `variants` are the copies in the provider's own order (as the Streams menu lists them); `tried` holds ids already attempted
    /// in this viewing, including the current one. Returns nil when nothing is left, or when the failure says another copy can't help.
    static func next(variants: [(variant: Channel, label: String)], tried: Set<String>, errorKind: PlaybackError.Kind) -> (variant: Channel, label: String)? {
        switch errorKind {
        case .authorization, .engineUnavailable: return nil         // a different copy needs the same login and the same engine
        // A busy provider (its one-connection limit) and a blocked server name affect every copy alike. Trying another copy only adds
        // connections to a server that is already refusing them, so these wait and retry the same stream instead.
        case .providerBusy, .nameLookup: return nil
        default: break
        }
        return variants.first { !tried.contains($0.variant.id) }
    }
}
