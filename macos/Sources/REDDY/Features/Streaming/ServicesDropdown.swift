import SwiftUI

extension Notification.Name {
    /// Posted by the Services menu command (⌘6): the top bar opens its Services list. It never opens a specific service.
    static let openServicesList = Notification.Name("StreamSetu.openServicesList")
}

/// What the Services list shows, as pure functions: the filter, the compact Recently Used section and the keyboard order.
struct ServicesMenuModel {
    struct Entry: Equatable, Identifiable {
        enum Section: Equatable { case recent, all }
        var section: Section
        var provider: ProviderID
        var id: String { (section == .recent ? "recent." : "all.") + provider.rawValue }
    }
    var nav: ServicesNavigationBinding

    /// A provider-name filter (not a content search): case-insensitive, matches the name or the id.
    static func matches(_ id: ProviderID, filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || id.title.localizedCaseInsensitiveContains(q) || id.rawValue.localizedCaseInsensitiveContains(q)
    }

    /// Local selections only: listed, no duplicates, at most three. Hidden while a filter is typed.
    func recents(filter: String) -> [ProviderID] {
        guard filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<ProviderID>()
        return Array(nav.recents.filter { nav.listed.contains($0) && seen.insert($0).inserted }.prefix(3))
    }

    func all(filter: String) -> [ProviderID] { nav.listed.filter { Self.matches($0, filter: filter) } }

    /// The rows in the order the arrow keys walk them.
    func entries(filter: String) -> [Entry] {
        recents(filter: filter).map { Entry(section: .recent, provider: $0) } + all(filter: filter).map { Entry(section: .all, provider: $0) }
    }
}

/// A recognisable vector badge for a service: its initial on a calm, fixed colour (no logos are fetched or bundled).
struct ServiceGlyph: View {
    let id: ProviderID
    var size: CGFloat = 24
    private static let palette: [Color] = [
        Color(hex: 0xB4232C), Color(hex: 0x2B6CB0), Color(hex: 0x1F8A70), Color(hex: 0x6B46C1), Color(hex: 0xC05621),
        Color(hex: 0x2C7A7B), Color(hex: 0x4A5568), Color(hex: 0xB83280), Color(hex: 0x5A67D8), Color(hex: 0x9C4221),
    ]
    static func color(for id: ProviderID) -> Color {
        let i = ProviderID.allCases.firstIndex(of: id) ?? abs(id.rawValue.hashValue)
        return palette[i % palette.count]
    }
    static func initial(for id: ProviderID) -> String { String(id.title.first.map { Character($0.uppercased()) } ?? "?") }
    var body: some View {
        Text(Self.initial(for: id))
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: id).gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The one Services list in the top bar: all services, each with its name, badge, state and two separate controls (Open, Pin). Opening and
/// pinning never trigger each other. Every keyboard action lives in the filter field (up/down move, Return opens, Option-Return pins, Esc
/// clears then closes), so plain keys never reach the player's key monitor from this window.
struct ServicesDropdown: View {
    let nav: ServicesNavigationBinding
    /// Services cannot be opened now (Kids profile, locked app). Pinning stays possible.
    var openDisabled = false
    var dismiss: () -> Void = {}
    @State private var filter = ""
    @State private var highlight = 0
    @FocusState private var filterFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reddyAccent) private var accent
    private var model: ServicesMenuModel { ServicesMenuModel(nav: nav) }

    var body: some View {
        let entries = model.entries(filter: filter)
        VStack(alignment: .leading, spacing: 6) {
            filterField(entries)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let recents = entries.filter { $0.section == .recent }
                        if !recents.isEmpty {
                            sectionTitle("Recently Used")
                            ForEach(recents) { row($0, entries) }
                            sectionTitle("All Services")
                        }
                        ForEach(entries.filter { $0.section == .all }) { row($0, entries) }
                        if entries.isEmpty { Text("No service matches").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(10) }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: highlight) { _, h in
                    guard entries.indices.contains(h) else { return }
                    if reduceMotion { proxy.scrollTo(entries[h].id) } else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(entries[h].id) } }
                }
            }
        }
        .padding(8).frame(width: 300)
        .onAppear { filterFocused = true }
        .onChange(of: filter) { _, _ in highlight = 0 }
        .accessibilityElement(children: .contain).accessibilityLabel("Services")
        .atlasScreen("screen.services.list")
    }

    private func filterField(_ entries: [ServicesMenuModel.Entry]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(ColorTokens.textTertiary)
            TextField("Filter services", text: $filter)
                .textFieldStyle(.plain).font(Typography.row).focused($filterFocused)
                .onKeyPress(.downArrow) { highlight = min(highlight + 1, max(0, entries.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlight = max(highlight - 1, 0); return .handled }
                .onKeyPress(.escape) { if filter.isEmpty { dismiss() } else { filter = "" }; return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard entries.indices.contains(highlight) else { return .handled }
                    let id = entries[highlight].provider
                    if press.modifiers.contains(.option) { nav.togglePin(id) } else if !openDisabled { nav.select(id); dismiss() }
                    return .handled
                }
                .accessibilityLabel("Filter services")
                .accessibilityHint("Type a service name. Up and Down choose, Return opens, Option Return pins or unpins.")
                .atlas("control.services.filter")
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    private func sectionTitle(_ t: LocalizedStringKey) -> some View {
        Text(t).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: ServicesMenuModel.Entry, _ entries: [ServicesMenuModel.Entry]) -> some View {
        let id = entry.provider
        let availability = nav.availability(id)
        let isActive = nav.active == id, pinned = nav.isPinned(id)
        let isHighlighted = entries.firstIndex(of: entry) == highlight
        return HStack(spacing: 6) {
            Button { nav.select(id); dismiss() } label: {
                HStack(spacing: 10) {
                    ServiceGlyph(id: id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(id.title).font(Typography.rowMedium).lineLimit(1)
                        if let b = availability.badgeTitle {
                            Text(LocalizedStringKey(b)).font(Typography.caption)
                                .foregroundStyle(availability == .available ? accent : ColorTokens.textSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if isActive { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(accent).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false).disabled(openDisabled)
            .accessibilityLabel(Text(ServiceAccessibility.openLabel(id, availability: availability, active: isActive, pinned: pinned)))
            .accessibilityHint("Opens this service")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .atlas("control.services.open")
            Button { nav.togglePin(id) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(pinned ? accent : ColorTokens.textSecondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false)
            .help(Text(pinned ? "Unpin from the top bar" : "Pin to the top bar"))
            .accessibilityLabel(Text(ServiceAccessibility.pinLabel(id, pinned: pinned)))
            .atlas("control.services.pin")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isHighlighted ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .id(entry.id)
        .accessibilityElement(children: .contain)
    }
}
