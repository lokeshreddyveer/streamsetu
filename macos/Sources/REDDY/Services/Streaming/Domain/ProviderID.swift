import Foundation

/// The stable identity of one streaming service. A plain string underneath (deep links, saved destinations and accessibility identifiers use it),
/// but `init?(rawValue:)` only accepts an id the registry knows, so decoding untrusted text can never invent a service. String literals are unchecked
/// on purpose: tests and fixtures name their own ids, and every route into a service is still checked by `ServiceCapabilities`.
struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, Identifiable, ExpressibleByStringLiteral, CaseIterable, CustomStringConvertible {
    let rawValue: String
    var id: String { rawValue }
    var description: String { rawValue }

    /// Known ids only (exact, case-sensitive).
    init?(rawValue: String) {
        guard ProviderRegistry.standard.definition(for: ProviderID(unchecked: rawValue)) != nil else { return nil }
        self.rawValue = rawValue
    }
    init(unchecked raw: String) { rawValue = raw }
    init(stringLiteral value: String) { rawValue = value }

    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    /// Every id in the registry, in catalog order.
    static var allCases: [ProviderID] { ProviderRegistry.standard.definitions.map(\.id) }

    /// The name shown in the top bar and the menus (a service name, not translated).
    var title: String { ProviderRegistry.standard.definition(for: self)?.displayName ?? rawValue }
}

/// Kept so existing code keeps compiling while callers move to `ProviderID`.
typealias ExternalService = ProviderID
