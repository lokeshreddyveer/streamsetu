import SwiftUI

extension Notification.Name {
    /// Posted by the Services menu command (⌘6): the top bar opens its Services list. It never opens a specific service.
    static let openServicesList = Notification.Name("StreamSetu.openServicesList")
}

/// What the Services list shows, as pure functions: one list where every service appears exactly once, in the sections Pinned (bar order),
/// Recent (not pinned, at most three) and More services (the rest), plus the filter and the keyboard order.
struct ServicesMenuModel {
    struct Entry: Equatable, Identifiable {
        enum Section: String, Equatable { case pinned, recent, more }
        var section: Section
        var provider: ProviderID
        /// 1-based place in the top bar, for pinned rows.
        var position: Int? = nil
        var id: String { section.rawValue + "." + provider.rawValue }
    }
    /// One row of the list in the order the arrow keys walk.
    enum Row: Equatable, Identifiable {
        case service(Entry)
        var id: String { switch self { case .service(let e): e.id } }
    }
    var nav: ServicesNavigationBinding

    func rows(filter: String) -> [Row] {
        entries(filter: filter).map(Row.service)
    }

    /// A provider-name filter (not a content search): case-insensitive, matches the name or the id.
    static func matches(_ id: ProviderID, filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || id.title.localizedCaseInsensitiveContains(q) || id.rawValue.localizedCaseInsensitiveContains(q)
    }

    /// Pinned services that are listed, in bar order (the position is the place in the bar, also while filtering).
    func pinned(filter: String) -> [Entry] {
        var seen = Set<ProviderID>()
        let all = nav.pinned.filter { nav.listed.contains($0) && seen.insert($0).inserted }
        return all.enumerated().filter { Self.matches($0.element, filter: filter) }.map { Entry(section: .pinned, provider: $0.element, position: $0.offset + 1) }
    }

    /// Local selections that are not pinned: listed, no duplicates, at most three. Hidden while a filter is typed.
    func recents(filter: String) -> [ProviderID] {
        guard filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<ProviderID>()
        return Array(nav.recents.filter { nav.listed.contains($0) && !nav.isPinned($0) && seen.insert($0).inserted }.prefix(3))
    }

    /// The remaining services, in catalogue order.
    func more(filter: String) -> [ProviderID] {
        let shown = Set(pinned(filter: "").map(\.provider)).union(recents(filter: filter))
        return nav.listed.filter { !shown.contains($0) && Self.matches($0, filter: filter) }
    }

    /// The rows in the order the arrow keys walk them.
    func entries(filter: String) -> [Entry] {
        pinned(filter: filter) + recents(filter: filter).map { Entry(section: .recent, provider: $0) } + more(filter: filter).map { Entry(section: .more, provider: $0) }
    }
}

/// A recognisable badge for a service: its bundled official icon, or its initial on a theme tile when there is none. Both sit in the same
/// squircle with a hairline edge and a faint top highlight, so every service looks like one family.
struct ServiceGlyph: View {
    let id: ProviderID
    var size: CGFloat = 24
    static func initial(for id: ProviderID) -> String { String(id.title.first.map { Character($0.uppercased()) } ?? "?") }
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Group {
            if let image = ServiceIconStore.icon(for: id) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill().frame(width: size, height: size).clipShape(shape)
            } else {
                Text(Self.initial(for: id))
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(ColorTokens.textPrimary)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [ColorTokens.elevated, ColorTokens.card], startPoint: .top, endPoint: .bottom), in: shape)
                    .overlay(shape.fill(accent.opacity(0.10)))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .overlay(shape.inset(by: 0.5).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

/// The opaque, theme-driven surface of the Services list: the theme's card colour (one step above the page), its sheen, a hairline edge,
/// an inner top highlight and a layered shadow. Nothing behind it can show through, so rows stay crisp on any page.
struct ServicesPanelSurface: View {
    static let radius: CGFloat = LayoutTokens.radiusPanel
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack {
            shape.fill(ColorTokens.panel)
            shape.fill(LinearGradient(colors: [accent.opacity(0.07), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
            GlossSheen(cornerRadius: Self.radius, streak: false)
        }
        .overlay(shape.strokeBorder(ColorTokens.lineStrong, lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .shadow(color: .black.opacity(0.30), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.50), radius: 1, y: 0.5)
    }
}

/// The one Services list in the top bar: every service exactly once, in Pinned, Recent and More services. Each row has its name, a status that
/// shows only when it matters, and two separate controls (Open, Pin). Opening and pinning never trigger each other. Every keyboard action
/// lives in the filter field (up/down move, Return opens, Option-Return pins, Esc clears then closes), so plain keys never reach the
/// player's key monitor from this window.
struct ServicesDropdown: View {
    let nav: ServicesNavigationBinding
    /// Services cannot be opened now (Kids profile, locked app). Pinning stays possible.
    var openDisabled = false
    /// The tallest the list may be; the caller lowers it for a short window.
    var maxListHeight: CGFloat = 400
    var dismiss: () -> Void = {}
    @State private var filter = ""
    @State private var highlight = 0
    @State private var contentHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @FocusState private var filterFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reddyAccent) private var accent
    private var model: ServicesMenuModel { ServicesMenuModel(nav: nav) }
    static let width: CGFloat = 336
    private static let inset: CGFloat = 6

    var body: some View {
        let rows = model.rows(filter: filter)
        let entries = model.entries(filter: filter)
        let listHeight = min(maxListHeight, max(contentHeight, 44))
        let scrolls = contentHeight > maxListHeight + 1
        VStack(alignment: .leading, spacing: 6) {
            filterField(rows)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        section("Pinned", .pinned, entries, rows)
                        section("Recent", .recent, entries, rows)
                        section("More services", .more, entries, rows)
                        if rows.isEmpty { emptyState }
                    }
                    .padding(.bottom, 2)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ServicesContentHeightKey.self, value: g.size.height)
                            .preference(key: ServicesScrollOffsetKey.self, value: g.frame(in: .named("servicesScroll")).minY)
                    })
                }
                .coordinateSpace(name: "servicesScroll")
                .frame(height: listHeight)
                .onPreferenceChange(ServicesContentHeightKey.self) { contentHeight = $0 }
                .onPreferenceChange(ServicesScrollOffsetKey.self) { scrollOffset = $0 }
                .mask(fadeMask(scrolls: scrolls, listHeight: listHeight))
                .onChange(of: highlight) { _, h in
                    guard rows.indices.contains(h) else { return }
                    if reduceMotion { proxy.scrollTo(rows[h].id) } else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[h].id) } }
                }
            }
        }
        .padding(Self.inset).frame(width: Self.width)
        .background(ServicesPanelSurface())
        .onAppear { DispatchQueue.main.async { filterFocused = true } }
        .onChange(of: filter) { _, _ in highlight = 0 }
        .accessibilityElement(children: .contain).accessibilityLabel("Services")
        .atlasScreen("screen.services.list")
    }

    /// Soft edges where the list continues: the top one only after scrolling, the bottom one while more is below.
    private func fadeMask(scrolls: Bool, listHeight: CGFloat) -> some View {
        let top = scrolls && scrollOffset < -2
        let bottom = scrolls && (-scrollOffset + listHeight) < contentHeight - 2
        return VStack(spacing: 0) {
            LinearGradient(colors: [top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, bottom ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(ColorTokens.textSecondary)
            Text("No service matches").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, _ kind: ServicesMenuModel.Entry.Section, _ entries: [ServicesMenuModel.Entry], _ all: [ServicesMenuModel.Row]) -> some View {
        let mine = entries.filter { $0.section == kind }
        if !mine.isEmpty {
            sectionTitle(title, first: all.first == .service(mine[0]))
            ForEach(mine) { row($0, all) }
        }
    }

    private func filterField(_ entries: [ServicesMenuModel.Row]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(filterFocused ? accent : ColorTokens.textSecondary)
            TextField("Filter services", text: $filter, prompt: Text("Filter services").foregroundStyle(ColorTokens.textSecondary))
                .textFieldStyle(.plain).font(Typography.body).foregroundStyle(ColorTokens.textPrimary).focused($filterFocused)
                .onKeyPress(.downArrow) { highlight = min(highlight + 1, max(0, entries.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlight = max(highlight - 1, 0); return .handled }
                .onKeyPress(.escape) { if filter.isEmpty { dismiss() } else { filter = "" }; return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard entries.indices.contains(highlight) else { return .handled }
                    switch entries[highlight] {
                    case .service(let e):
                        if press.modifiers.contains(.option) { nav.togglePin(e.provider) } else if !openDisabled { nav.select(e.provider); dismiss() }
                    }
                    return .handled
                }
                .accessibilityLabel("Filter services")
                .accessibilityHint("Type a service name. Up and Down choose, Return opens, Option Return pins or unpins.")
                .atlas("control.services.filter")
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(ColorTokens.textSecondary)
                }
                .buttonStyle(.plain).focusable(false).accessibilityLabel("Clear filter").atlas("control.services.filter")
            }
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background(ColorTokens.background.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(filterFocused ? accent.opacity(0.65) : ColorTokens.line, lineWidth: filterFocused ? 1 : 0.75))
        .shadow(color: filterFocused ? accent.opacity(0.20) : .clear, radius: 5)
        .animation(reduceMotion ? nil : AnimationTokens.quick, value: filterFocused)
    }

    private func sectionTitle(_ t: LocalizedStringKey, first: Bool) -> some View {
        Text(t).font(Typography.eyebrow).textCase(.uppercase).tracking(0.9).foregroundStyle(ColorTokens.textSecondary)
            .padding(.horizontal, 12).padding(.top, first ? 8 : 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            .atlas("control.services.section")
    }

    private func row(_ entry: ServicesMenuModel.Entry, _ entries: [ServicesMenuModel.Row]) -> some View {
        let id = entry.provider
        let index = entries.firstIndex(of: .service(entry)) ?? 0
        return ServicesRow(
            id: id, entry: entry, nav: nav, openDisabled: openDisabled, highlighted: index == highlight,
            onHover: { if $0 { highlight = index } }, dismiss: dismiss)
            .id(entry.id)
    }
}

/// One 44pt row: marker, icon tile, name, "Open now" when it is the service on screen, and the separate Pin control.
private struct ServicesRow: View {
    let id: ProviderID
    let entry: ServicesMenuModel.Entry
    let nav: ServicesNavigationBinding
    let openDisabled: Bool
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let dismiss: () -> Void
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let availability = nav.availability(id)
        let isActive = nav.active == id, pinned = nav.isPinned(id)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let wash: Color = isActive ? accent.opacity(highlighted ? 0.18 : 0.13) : (highlighted ? ColorTokens.textPrimary.opacity(0.07) : .clear)
        HStack(spacing: 0) {
            Button { nav.select(id); dismiss() } label: {
                HStack(spacing: 10) {
                    ServiceGlyph(id: id, size: 30)
                    Text(id.title).font(Typography.bodyMedium).fontWeight(isActive ? .semibold : .medium).foregroundStyle(ColorTokens.textPrimary).lineLimit(1)
                    Spacer(minLength: 6)
                    status(availability, active: isActive)
                }
                .padding(.leading, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(ServicesRowPressStyle(shape: shape)).focusable(false).disabled(openDisabled)
            .accessibilityLabel(Text(ServiceAccessibility.openLabel(id, availability: availability, active: isActive, pinned: pinned, position: entry.position)))
            .accessibilityHint("Opens this service")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .atlas("control.services.open")
            pinButton(pinned: pinned)
        }
        .frame(height: 44)
        .background(wash, in: shape)
        .overlay(alignment: .leading) {
            if isActive {
                Capsule().fill(accent).frame(width: 3, height: 18).shadow(color: accent.opacity(0.6), radius: 3).padding(.leading, 2)
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0; onHover($0) }
        .animation(reduceMotion ? nil : AnimationTokens.hover, value: highlighted)
        .animation(reduceMotion ? nil : AnimationTokens.hover, value: isActive)
        .accessibilityElement(children: .contain)
        .modifier(PinnedRowReorder(id: id, pinned: pinned, nav: nav))
    }

    /// Nothing is shown about whether a service has been checked; only a service that cannot be opened carries a badge.
    @ViewBuilder private func status(_ availability: ServiceAvailability, active: Bool) -> some View {
        if availability == .disabled {
            Text("Disabled").font(Typography.micro).foregroundStyle(ColorTokens.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(ColorTokens.textPrimary.opacity(0.10), in: Capsule())
        } else if active {
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 5, height: 5).shadow(color: accent.opacity(0.7), radius: 3)
                Text("Open now").font(Typography.captionMedium).foregroundStyle(ColorTokens.textPrimary)
            }
        }
    }

    private func pinButton(pinned: Bool) -> some View {
        Button { nav.togglePin(id) } label: {
            Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .foregroundStyle(pinned ? accent : ColorTokens.textSecondary.opacity(highlighted || hovering ? 1 : 0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(pinned ? accent.opacity(0.16) : (hovering ? ColorTokens.textPrimary.opacity(0.08) : .clear)))
                .overlay(Circle().strokeBorder(pinned ? accent.opacity(0.35) : .clear, lineWidth: 0.75))
                .shadow(color: pinned ? accent.opacity(0.45) : .clear, radius: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).focusable(false)
        .padding(.horizontal, 7)
        .animation(reduceMotion ? nil : AnimationTokens.hover, value: pinned)
        .help(Text(ServiceAccessibility.pinLabel(id, pinned: pinned)))
        .accessibilityLabel(Text(ServiceAccessibility.pinLabel(id, pinned: pinned)))
        .atlas("control.services.pin")
    }
}

/// Pressed wash for the Open area of a row.
private struct ServicesRowPressStyle: ButtonStyle {
    let shape: RoundedRectangle
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? ColorTokens.textPrimary.opacity(0.07) : .clear, in: shape)
    }
}

private struct ServicesScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ServicesContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Move Up and Move Down for a pinned row, as accessibility actions and in the row's right-click menu.
private struct PinnedRowReorder: ViewModifier {
    let id: ProviderID
    let pinned: Bool
    let nav: ServicesNavigationBinding
    func body(content: Content) -> some View {
        if pinned {
            content
                .accessibilityAction(named: Text("Move Up")) { nav.moveLeft(id) }
                .accessibilityAction(named: Text("Move Down")) { nav.moveRight(id) }
                .contextMenu {
                    Button("Move Up") { nav.moveLeft(id) }.disabled(!nav.canMoveLeft(id)).atlas("control.services.move")
                    Button("Move Down") { nav.moveRight(id) }.disabled(!nav.canMoveRight(id)).atlas("control.services.move")
                }.atlas("control.services.move")
        } else { content }
    }
}
