import SwiftUI
import UniformTypeIdentifiers

/// What the top bar needs to show and drive the services: the pinned ids in order, the active one, the recents, an availability lookup and
/// the callbacks. RootView builds one from `ServicePreferences` and `ServiceNavigation`; the views below only read it and call back.
/// Pinning is presentation only: `togglePin` never navigates and never touches a service's data.
struct ServicesNavigationBinding {
    /// Every service the menu lists, in catalog order.
    var listed: [ProviderID] = ProviderRegistry.standard.listed(on: .macOS).map(\.id)
    var pinned: [ProviderID] = []
    /// Most recent first, at most three, ids only.
    var recents: [ProviderID] = []
    var active: ProviderID?
    var availability: (ProviderID) -> ServiceAvailability = { ProviderRegistry.standard.definition(for: $0)?.availability ?? .registered }
    var select: (ProviderID) -> Void = { _ in }
    var togglePin: (ProviderID) -> Void = { _ in }
    /// Moves a pinned id to an index of the pinned list.
    var move: (ProviderID, Int) -> Void = { _, _ in }

    static var empty: ServicesNavigationBinding { ServicesNavigationBinding() }

    func isPinned(_ id: ProviderID) -> Bool { pinned.contains(id) }
    func canMoveLeft(_ id: ProviderID) -> Bool { (pinned.firstIndex(of: id) ?? 0) > 0 }
    func canMoveRight(_ id: ProviderID) -> Bool { pinned.firstIndex(of: id).map { $0 < pinned.count - 1 } ?? false }
    func moveLeft(_ id: ProviderID) { if let i = pinned.firstIndex(of: id), i > 0 { move(id, i - 1) } }
    func moveRight(_ id: ProviderID) { if let i = pinned.firstIndex(of: id), i < pinned.count - 1 { move(id, i + 1) } }
}

extension ServiceAvailability {
    /// The badge word for a service row; `registered` services are never listed.
    var badgeTitle: String? {
        switch self { case .available: "Available"; case .unverified: "Unverified"; case .disabled: "Disabled"; case .registered: nil }
    }
}

/// The accessible name and value of a service control, in one place so the bar, the menu and the tests agree.
enum ServiceAccessibility {
    static func openLabel(_ id: ProviderID, availability: ServiceAvailability, active: Bool, pinned: Bool) -> String {
        var parts = [id.title]
        if let b = availability.badgeTitle { parts.append(b) }
        if active { parts.append("open now") }
        if pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
    static func pinLabel(_ id: ProviderID, pinned: Bool) -> String { pinned ? "Unpin \(id.title) from the top bar" : "Pin \(id.title) to the top bar" }
}

/// The pinned services as a row of items, with everything a pinned item can do besides open: a context menu (Pin/Unpin, Move Left/Right),
/// the same as accessibility actions, and drag to reorder. The look of one item comes from the top bar (`item`), so it matches the tabs.
struct PinnedServicesBar<Item: View>: View {
    let ids: [ProviderID]
    let nav: ServicesNavigationBinding
    var disabled = false
    @ViewBuilder var item: (ProviderID) -> Item

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ids) { id in
                item(id).pinnedBehaviour(id, nav: nav, disabled: disabled)
            }
        }
    }
}

extension View {
    /// Context menu, accessibility actions and drag-to-reorder for one pinned item.
    func pinnedBehaviour(_ id: ProviderID, nav: ServicesNavigationBinding, disabled: Bool = false) -> some View {
        modifier(PinnedItemBehaviour(id: id, nav: nav, disabled: disabled))
    }
    /// Context menu and accessibility actions for the active service when it is not pinned.
    func unpinnedActiveBehaviour(_ id: ProviderID, nav: ServicesNavigationBinding) -> some View {
        modifier(UnpinnedItemBehaviour(id: id, nav: nav))
    }
}

private struct PinnedItemBehaviour: ViewModifier {
    let id: ProviderID
    let nav: ServicesNavigationBinding
    let disabled: Bool

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open \(id.title)") { nav.select(id) }.disabled(disabled).atlas("control.services.open")
                Divider()
                Button("Unpin from Top Bar") { nav.togglePin(id) }.atlas("control.services.pin")
                Button("Move Left") { nav.moveLeft(id) }.disabled(!nav.canMoveLeft(id)).atlas("control.services.move")
                Button("Move Right") { nav.moveRight(id) }.disabled(!nav.canMoveRight(id)).atlas("control.services.move")
            }.atlas("control.services.pin")
            .accessibilityAction(named: Text("Unpin from Top Bar")) { nav.togglePin(id) }
            .accessibilityAction(named: Text("Move Left")) { nav.moveLeft(id) }
            .accessibilityAction(named: Text("Move Right")) { nav.moveRight(id) }
            .draggable(PinnedServiceDrag(id: id.rawValue))
            .dropDestination(for: PinnedServiceDrag.self) { items, _ in
                guard let raw = items.first?.id, nav.pinned.contains(ProviderID(unchecked: raw)), let target = nav.pinned.firstIndex(of: id) else { return false }
                nav.move(ProviderID(unchecked: raw), target); return true
            }
    }
}

private struct UnpinnedItemBehaviour: ViewModifier {
    let id: ProviderID
    let nav: ServicesNavigationBinding
    func body(content: Content) -> some View {
        content
            .contextMenu { Button("Pin to Top Bar") { nav.togglePin(id) }.atlas("control.services.pin") }.atlas("control.services.pin")
            .accessibilityAction(named: Text("Pin to Top Bar")) { nav.togglePin(id) }
    }
}

/// What a pinned item carries while it is dragged to a new place. Not text, so it cannot be dropped into a text field; the drop checks the id
/// against the pinned list.
struct PinnedServiceDrag: Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .data) { Data($0.id.utf8) } importing: { PinnedServiceDrag(id: String(decoding: $0, as: UTF8.self)) }
    }
}
