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
    /// Reload works only for the service on screen, and only when it has a live web view.
    var canReload: (ProviderID) -> Bool = { _ in false }
    var reload: (ProviderID) -> Void = { _ in }
    /// Clear Data works for a service shown inside the app. The callback asks first (the shared confirmation) and clears only that service.
    var canClearData: (ProviderID) -> Bool = { _ in false }
    var clearData: (ProviderID) -> Void = { _ in }

    /// How each native item of the first group is drawn (icon and name, icon only, name only). None of them can be hidden.
    var tabModes = TopBarTabModes()
    var setTabMode: (NavTab, TabBarMode) -> Void = { _, _ in }
    /// False where Podcasts cannot be opened at all (a Kids profile, a locked app): then it is not in the bar. One rule decides.
    var podcastsAvailable = true
    /// The same rule for Music. Off until the shell turns it on, so the bar's six-item layouts stay as they were.
    var musicAvailable = false
    /// Services playing in the background right now (not the one showing): each gets a small speaker badge on its chip and its list row.
    var playing: Set<ProviderID> = []

    static var empty: ServicesNavigationBinding { ServicesNavigationBinding() }

    func isPlaying(_ id: ProviderID) -> Bool { playing.contains(id) }
    func isPinned(_ id: ProviderID) -> Bool { pinned.contains(id) }
    func canMoveLeft(_ id: ProviderID) -> Bool { (pinned.firstIndex(of: id) ?? 0) > 0 }
    func canMoveRight(_ id: ProviderID) -> Bool { pinned.firstIndex(of: id).map { $0 < pinned.count - 1 } ?? false }
    func moveLeft(_ id: ProviderID) { if let i = pinned.firstIndex(of: id), i > 0 { move(id, i - 1) } }
    func moveRight(_ id: ProviderID) { if let i = pinned.firstIndex(of: id), i < pinned.count - 1 { move(id, i + 1) } }
}

extension ServiceAvailability {
    /// The badge word for a service row: only a service that cannot be opened has one.
    var badgeTitle: String? { self == .disabled ? "Disabled" : nil }
}

/// The accessible name and value of a service control, in one place so the bar, the menu and the tests agree.
enum ServiceAccessibility {
    static func openLabel(_ id: ProviderID, availability: ServiceAvailability, active: Bool, pinned: Bool, position: Int? = nil, playing: Bool = false) -> String {
        var parts = [id.title]
        if let b = availability.badgeTitle { parts.append(b) }
        if let n = position { parts.append("position \(n)") }
        if active { parts.append("open now") }
        if pinned { parts.append("pinned") }
        if playing { parts.append(playingLabel) }
        return parts.joined(separator: ", ")
    }
    /// The accessible name of the speaker badge on a service that plays in the background.
    static let playingLabel = "Playing"
    static func pinLabel(_ id: ProviderID, pinned: Bool) -> String { pinned ? "Unpin \(id.title)" : "Pin \(id.title)" }
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

extension View {
    /// Right-click menu and accessibility actions of a native item: Icon and Name, Icon Only, Name Only, the current one checked.
    func tabModeMenu(_ tab: NavTab, nav: ServicesNavigationBinding) -> some View { modifier(TabModeMenu(tab: tab, nav: nav)) }
}

private struct TabModeMenu: ViewModifier {
    let tab: NavTab
    let nav: ServicesNavigationBinding
    func body(content: Content) -> some View {
        let current = nav.tabModes.mode(tab)
        content
            .contextMenu {
                ForEach(TabBarMode.allCases) { m in
                    Button { nav.setTabMode(tab, m) } label: { Label(LocalizedStringKey(m.title), systemImage: m == current ? "checkmark" : "") }.atlas("control.nav.tabMode")
                }
            }
            .atlas("control.nav.tabMode")
            .accessibilityAction(named: Text("Icon and Name")) { nav.setTabMode(tab, .iconAndName) }
            .accessibilityAction(named: Text("Icon Only")) { nav.setTabMode(tab, .iconOnly) }
            .accessibilityAction(named: Text("Name Only")) { nav.setTabMode(tab, .nameOnly) }
    }
}

private struct PinnedItemBehaviour: ViewModifier {
    let id: ProviderID
    let nav: ServicesNavigationBinding
    let disabled: Bool
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                ServicePillActions(id: id, nav: nav, inPopover: false)
            }.atlas("control.services.pillmenu")
            .simultaneousGesture(TapGesture(count: 2).onEnded { open = true })
            .popover(isPresented: $open, arrowEdge: .bottom) { ServicePillActions(id: id, nav: nav, inPopover: true, dismiss: { open = false }) }
            .accessibilityAction(named: Text("Reload")) { if nav.canReload(id) { nav.reload(id) } }
            .accessibilityAction(named: Text("Unpin from Top Bar")) { nav.togglePin(id) }
            .accessibilityAction(named: Text("Move Left")) { nav.moveLeft(id) }
            .accessibilityAction(named: Text("Move Right")) { nav.moveRight(id) }
            .accessibilityAction(named: Text("Clear Data…")) { if nav.canClearData(id) { nav.clearData(id) } }
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
    @State private var open = false
    func body(content: Content) -> some View {
        content
            .contextMenu { ServicePillActions(id: id, nav: nav, inPopover: false) }.atlas("control.services.pillmenu")
            .simultaneousGesture(TapGesture(count: 2).onEnded { open = true })
            .popover(isPresented: $open, arrowEdge: .bottom) { ServicePillActions(id: id, nav: nav, inPopover: true, dismiss: { open = false }) }
            .accessibilityAction(named: Text("Reload")) { if nav.canReload(id) { nav.reload(id) } }
            .accessibilityAction(named: Text("Pin to Top Bar")) { nav.togglePin(id) }
            .accessibilityAction(named: Text("Clear Data…")) { if nav.canClearData(id) { nav.clearData(id) } }
    }
}

/// One entry of a service pill's menu.
struct ServicePillItem: Equatable {
    enum Kind: Equatable { case reload, pin, unpin, moveLeft, moveRight, clearData }
    let kind: Kind
    let enabled: Bool
    var title: String {
        switch kind {
        case .reload: "Reload"
        case .pin: "Pin to Top Bar"
        case .unpin: "Unpin from Top Bar"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .clearData: "Clear Data…"
        }
    }
    var atlas: String {
        switch kind {
        case .reload: "control.nav.service.reload"
        case .pin, .unpin: "control.services.pillmenu"
        case .moveLeft, .moveRight: "control.services.move"
        case .clearData: "control.services.clearData"
        }
    }

    /// The menu of one pill, for its current state: Reload, Pin or Unpin, Move Left and Move Right (pinned only), Clear Data. There is no
    /// Open item: a single click on the pill already opens the service.
    static func items(for id: ProviderID, nav: ServicesNavigationBinding) -> [ServicePillItem] {
        let pinned = nav.isPinned(id)
        var list = [ServicePillItem(kind: .reload, enabled: nav.canReload(id)),
                    ServicePillItem(kind: pinned ? .unpin : .pin, enabled: true)]
        if pinned {
            list.append(ServicePillItem(kind: .moveLeft, enabled: nav.canMoveLeft(id)))
            list.append(ServicePillItem(kind: .moveRight, enabled: nav.canMoveRight(id)))
        }
        list.append(ServicePillItem(kind: .clearData, enabled: nav.canClearData(id)))
        return list
    }
}

/// The actions of a service pill in the top bar. The right-click menu and the double-click popover show this same list, so a double click can
/// never change a pin by itself.
struct ServicePillActions: View {
    let id: ProviderID
    let nav: ServicesNavigationBinding
    var inPopover: Bool
    var dismiss: () -> Void = {}

    var body: some View {
        let items = ServicePillItem.items(for: id, nav: nav)
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if item.kind == .clearData || (index == 1 && inPopover) { Divider() }
            action(item).atlas(item.atlas)
        }
    }

    private func run(_ item: ServicePillItem) {
        switch item.kind {
        case .reload: nav.reload(id)
        case .pin, .unpin: nav.togglePin(id)
        case .moveLeft: nav.moveLeft(id)
        case .moveRight: nav.moveRight(id)
        case .clearData: nav.clearData(id)
        }
    }

    @ViewBuilder private func action(_ item: ServicePillItem) -> some View {
        if inPopover {
            Button { run(item); dismiss() } label: {
                Text(item.title.loc).foregroundStyle(item.kind == .clearData ? ColorTokens.danger : ColorTokens.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!item.enabled).frame(width: 170).atlas("control.services.pillmenu")
        } else if item.kind == .clearData {
            Button(role: .destructive) { run(item) } label: { Text(item.title.loc) }.disabled(!item.enabled).atlas("control.services.pillmenu")
        } else {
            Button { run(item) } label: { Text(item.title.loc) }.disabled(!item.enabled).atlas("control.services.pillmenu")
        }
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
