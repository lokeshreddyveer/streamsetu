import Foundation

struct ServiceBarPlan: Equatable, Sendable {
    /// Pinned items shown in the row, in pinned order.
    var inline: [ProviderID]
    /// Pinned items that did not fit, in pinned order (they stay reachable in the Services menu).
    var overflow: [ProviderID]
    /// The active service when it is not pinned: identifiable and reachable without being pinned.
    var temporaryChip: ProviderID?
    var showsServicesButton: Bool
}

/// Pure single-row planning. Inputs are measured widths; the output says what is inline, what overflows and whether a temporary chip is needed.
/// The active service is never overflowed; items are dropped from the END of the pinned order until the row fits.
enum ServiceBarPlanner {
    static func plan(pinned: [ProviderID], active: ProviderID?, itemWidths: [ProviderID: CGFloat], servicesButtonWidth: CGFloat,
                     budget: CGFloat, spacing: CGFloat = 0) -> ServiceBarPlan {
        var seen = Set<ProviderID>()
        var inline = pinned.filter { seen.insert($0).inserted }
        let chip: ProviderID? = active.flatMap { inline.contains($0) ? nil : $0 }
        func width(_ id: ProviderID) -> CGFloat { max(0, itemWidths[id] ?? 0) }
        func total() -> CGFloat {
            var ids = inline; if let chip { ids.append(chip) }
            let items = ids.reduce(CGFloat(0)) { $0 + width($1) }
            let count = ids.count + 1          // the Services button is always present
            return items + max(0, servicesButtonWidth) + spacing * CGFloat(count - 1)
        }
        var overflow: [ProviderID] = []
        while total() > budget, let i = inline.lastIndex(where: { $0 != active }) {
            overflow.insert(inline.remove(at: i), at: 0)
        }
        return ServiceBarPlan(inline: inline, overflow: overflow, temporaryChip: chip, showsServicesButton: true)
    }
}
