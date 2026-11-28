import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The payload of a folder row being dragged to a new place. It is a private type of this app, never text, so dropping it on the
/// window (which accepts playlist links as text) does nothing, and no other app can read it.
enum SidebarFolderDrag {
    static let identifier = "com.streamsetu.sidebar-folder"
    static var type: UTType { UTType(importedAs: identifier) }

    static func provider(for id: String) -> NSItemProvider {
        let p = NSItemProvider()
        let data = Data(id.utf8)
        p.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .ownProcess) { done in done(data, nil); return nil }
        return p
    }

    /// True for a provider made by `provider(for:)`, so a window-level drop can leave it alone.
    static func isFolder(_ p: NSItemProvider) -> Bool { p.hasItemConformingToTypeIdentifier(identifier) }
}

struct PlaylistEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct SidebarViewState {
    var title: String
    var pinned: [SidebarEntry]
    var folders: [SidebarEntry]
    var selection: SidebarSelection
    var collapsed: Bool
    var playlistName: String?
    var playlists: [PlaylistEntry]
    var activePlaylistID: UUID?
    var playlistMenuOpen: Bool
    var folderSectionTitle = "Folders"
    /// Changes when a folder was asked for by name (a link, a search result), so its row is shown even if it was already selected.
    var revealToken = 0
}

/// Where the open playlist menu is, so the click-away layer can leave exactly that rectangle alone.
struct PlaylistMenuBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// What a click closes the playlist menu from: everything below the top bar and beside the sidebar, except the menu itself (which can reach past the collapsed sidebar).
/// Used with the even-odd rule, so the menu's rectangle is a hole.
struct PlaylistClickAwayShape: Shape {
    var top: CGFloat
    var leading: CGFloat
    var menu: CGRect?

    func path(in rect: CGRect) -> Path {
        let area = CGRect(x: rect.minX + leading, y: rect.minY + top, width: max(0, rect.width - leading), height: max(0, rect.height - top))
        var p = Path(area)
        if let hole = menu?.intersection(area), !hole.isNull, !hole.isEmpty { p.addRect(hole) }
        return p
    }
}

/// Contextual sidebar with three independent regions:
/// fixed shortcuts on top, a folder list that alone scrolls, and fixed playlist controls at the bottom.
struct ReddySidebar: View {
    let state: SidebarViewState
    @Binding var folderQuery: String
    var onSelect: (SidebarSelection) -> Void
    var onToggleCollapse: () -> Void
    var onTogglePlaylistMenu: () -> Void
    var onSwitchPlaylist: (UUID) -> Void
    var onAddPlaylist: () -> Void
    /// Right-click "Remove…" on a playlist row (not on "All Playlists"). Nil leaves the menu without it.
    var onRemovePlaylist: ((UUID) -> Void)?
    /// New folder order (entry ids) after a drag or a menu move. Nil turns reordering off.
    var onReorder: (([String]) -> Void)?
    var onHideFolder: ((String) -> Void)?
    /// Parental lock: which folders are locked, whether a PIN exists / is entered, and the action to lock or unlock one.
    var lockedFolderIDs: Set<String> = []
    var parentalAvailable = false
    var onLockFolder: ((String, Bool) -> Void)?
    @State private var working: [SidebarEntry]?
    @State private var dragging: String?
    @State private var hovered: String?
    @State private var scroller = DragAutoScroller()
    @Environment(\.reddyAccent) private var accent
    /// The selected row's background slides from row to row.
    @Namespace private var selectionSlide
    @Environment(\.reddyDensity) private var density

    /// The playlist menu never gets narrower than this, so it stays readable beside the collapsed sidebar; it then reaches past the sidebar.
    static let menuMinWidth: CGFloat = 176
    private static let menuInset: CGFloat = 6
    static func sidebarWidth(collapsed: Bool) -> CGFloat { collapsed ? LayoutTokens.sidebarCollapsedWidth : LayoutTokens.sidebarWidth }
    static func menuWidth(collapsed: Bool) -> CGFloat { max(menuMinWidth, sidebarWidth(collapsed: collapsed) - 16) }

    private var width: CGFloat { Self.sidebarWidth(collapsed: state.collapsed) }
    private var showsSearch: Bool { !state.collapsed && !state.folders.isEmpty }
    private var footerHeight: CGFloat { showsSearch ? 84 : 46 }
    private var appliedQuery: String { SidebarModel.appliedQuery(folderQuery, collapsed: state.collapsed) }
    private var visibleFolders: [SidebarEntry] { working ?? SidebarModel.filter(state.folders, query: appliedQuery) }
    private var canReorder: Bool { onReorder != nil && appliedQuery.isEmpty }
    private func isMovable(_ e: SidebarEntry) -> Bool { SidebarModel.isMovable(e) }
    private func title(_ key: String) -> String { Localized.string(key) }

    var body: some View {
        VStack(spacing: 0) {
            head                                            // fixed
            VStack(spacing: 2) { ForEach(state.pinned) { row($0) } }.padding(.horizontal, 10)   // fixed shortcuts
            foldersRegion                                   // the only scrolling region
            footer                                          // fixed
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
        .clipped()
        // Opens upward from the selector. It is at least `menuMinWidth` wide, so beside the collapsed sidebar it reaches over the page, never out of the window.
        .overlay(alignment: .bottomLeading) {
            if state.playlistMenuOpen {
                playlistMenu.anchorPreference(key: PlaylistMenuBoundsKey.self, value: .bounds) { $0 }
                    .padding(.leading, Self.menuInset).padding(.bottom, footerHeight + 4).transition(.opacity)
            }
        }
        .animation(AnimationTokens.standard, value: state.collapsed)
    }

    private var sidebarBackground: some View {
        ZStack {
            if ColorTokens.nativeGlass { NativeGlass(shape: Rectangle(), tint: ColorTokens.panel.opacity(0.25)) }
            else if ColorTokens.glassy { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(ColorTokens.panel.opacity(0.5)) }
            else { Rectangle().fill(ColorTokens.panel) }
            GlossSheen()
        }
    }

    private var head: some View {
        HStack {
            if !state.collapsed { Text(title(state.title)).textCase(.uppercase).font(Typography.eyebrow).tracking(1.5).foregroundStyle(ColorTokens.textSecondary) }
            Spacer(minLength: 0)
            Button(action: onToggleCollapse) {
                Image(systemName: "sidebar.left").font(.system(size: 14, weight: .regular)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary)
            .accessibilityLabel(title(state.collapsed ? "Expand sidebar" : "Collapse sidebar")).atlas("control.sidebar.collapse")
        }
        .padding(.leading, state.collapsed ? 0 : 22).padding(.trailing, state.collapsed ? 0 : 10).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
    }

    private var foldersRegion: some View {
        VStack(spacing: 0) {
            if !state.folders.isEmpty {
                Rectangle().fill(ColorTokens.line).frame(height: 1).padding(.horizontal, 12).padding(.top, 8)
                if !state.collapsed {
                    Text(title(state.folderSectionTitle)).textCase(.uppercase).font(Typography.eyebrow).tracking(1.3).foregroundStyle(ColorTokens.textTertiary)
                        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) { ForEach(visibleFolders) { folderRow($0) } }.padding(.horizontal, 10).padding(.bottom, 8)
                            .animation(AnimationTokens.hover, value: visibleFolders.map(\.id))
                    }
                    .background(ViewProbe(scroller: scroller))
                    // The selected folder is brought into view when it is chosen from elsewhere (an "In folder" link, a search result).
                    .onAppear { reveal(proxy) }
                    .onChange(of: state.selection) { _, _ in reveal(proxy) }
                    .onChange(of: state.revealToken) { _, _ in reveal(proxy) }
                    // A folder chosen before its list had loaded (a playlist switch, a remembered folder at launch) is brought into view when the list arrives.
                    .onChange(of: state.folders.map(\.id)) { _, _ in if dragging == nil { reveal(proxy) } }
                    // While a folder is being dragged, holding it near the top or bottom edge of the list scrolls the list.
                    .onChange(of: dragging) { _, d in
                        if d == nil { scroller.stop(); hovered = nil; return }
                        scroller.start(onEnd: { endDrag() }) { dir in
                            let list = visibleFolders
                            guard !list.isEmpty else { return }
                            let at = [hovered, dragging].compactMap { $0 }.compactMap { id in list.firstIndex { $0.id == id } }.first ?? 0
                            let target = min(max(0, at + dir * 3), list.count - 1)
                            withAnimation(.linear(duration: 0.07)) { proxy.scrollTo(list[target].id, anchor: dir < 0 ? .top : .bottom) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Letting go anywhere in the list (a gap, the edge) still drops the folder where it was held.
                .onDrop(of: [SidebarFolderDrag.type], delegate: FolderDropDelegate(target: nil, working: $working, dragging: $dragging, hovered: $hovered, movable: isMovable, restore: { state.folders }) { ids in onReorder?(ids) })
                .onChange(of: state.folders) { _, _ in endDrag() }
                .frame(maxHeight: .infinity)                // takes whatever is left, and shrinks, so only this region scrolls
                .accessibilityLabel(title(state.folderSectionTitle))
                if visibleFolders.isEmpty && !folderQuery.isEmpty && !state.collapsed {
                    Text(title("No matching folders")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 22).padding(.bottom, 6)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Shows the selected folder's row: a folder search that hides it is cleared first.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let r = SidebarModel.reveal(state.selection, in: state.folders, query: appliedQuery) else { return }
        if r.clearsSearch { folderQuery = "" }
        Task { @MainActor in proxy.scrollTo(r.rowID) }          // after the list has the row again
    }

    /// A drag that did not end in a drop (let go outside the list, or cancelled) leaves nothing behind.
    private func endDrag() { working = nil; dragging = nil; hovered = nil; scroller.stop() }

    private func menuPlan(_ e: SidebarEntry, reorder: Bool) -> SidebarModel.FolderMenuPlan {
        SidebarModel.folderMenu(for: e, in: state.folders, canReorder: reorder, canHide: onHideFolder != nil, parentalAvailable: parentalAvailable, canLock: onLockFolder != nil, lockedIDs: lockedFolderIDs)
    }

    /// A folder row: the normal row, plus drag-to-reorder and a menu with the same moves for keyboard and trackpad users.
    @ViewBuilder private func folderRow(_ e: SidebarEntry) -> some View {
        let reorder = canReorder && isMovable(e)
        let plan = menuPlan(e, reorder: reorder)
        if reorder {
            row(e)
                .opacity(dragging == e.id ? 0.45 : 1)
                .onDrag { dragging = e.id; working = state.folders; return SidebarFolderDrag.provider(for: e.id) }
                .onDrop(of: [SidebarFolderDrag.type], delegate: FolderDropDelegate(target: e, working: $working, dragging: $dragging, hovered: $hovered, movable: isMovable, restore: { state.folders }) { ids in onReorder?(ids) })
                .contextMenu { folderMenu(e, plan) }.atlas("context.sidebar.folderReorder")
        } else if !plan.isEmpty {
            row(e).contextMenu { folderMenu(e, plan) }.atlas("context.sidebar.folderReorder")
        } else {
            row(e)
        }
    }

    @ViewBuilder private func folderMenu(_ e: SidebarEntry, _ plan: SidebarModel.FolderMenuPlan) -> some View {
        if plan.moves {
            Button("Move to Top") { move(e, to: 0) }.disabled(!plan.moveUp)
            Button("Move Up") { move(e, by: -1) }.disabled(!plan.moveUp)
            Button("Move Down") { move(e, by: 1) }.disabled(!plan.moveDown)
            Button("Move to Bottom") { move(e, to: Int.max) }.disabled(!plan.moveDown)
        }
        if case .folder(let id) = e.selection {
            if plan.hide, let onHideFolder { if plan.moves { Divider() }; Button("Hide Folder") { onHideFolder(id) } }
            if let onLockFolder, plan.lock || plan.unlock {
                if plan.moves || plan.hide { Divider() }
                if plan.unlock { Button("Unlock Folder") { onLockFolder(id, false) } }
                else { Button("Lock Folder with PIN") { onLockFolder(id, true) } }
            }
        }
    }

    private func move(_ e: SidebarEntry, by delta: Int) {
        let list = state.folders
        guard let i = list.firstIndex(of: e) else { return }
        move(e, to: i + delta)
    }

    private func move(_ e: SidebarEntry, to index: Int) {
        var list = state.folders
        guard let i = list.firstIndex(of: e) else { return }
        let movableCount = list.filter(isMovable).count
        let j = min(max(0, index), movableCount - 1)
        guard j != i else { return }
        list.remove(at: i); list.insert(e, at: j)
        onReorder?(list.map(\.id))
    }

    private func row(_ e: SidebarEntry) -> some View {
        let selected = state.selection == e.selection
        let locked: Bool = { if case .folder(let id) = e.selection { lockedFolderIDs.contains(id) } else { false } }()
        let name = e.displayTitle
        let count = (e.count ?? 0) > 0 ? e.count : nil
        return Button { onSelect(e.selection) } label: {
            HStack(spacing: 10) {
                Image(systemName: e.symbol).font(.system(size: 14, weight: .regular)).frame(width: 20)
                    // a locked folder still shows it when the sidebar is collapsed
                    .overlay(alignment: .bottomTrailing) {
                        if locked && state.collapsed { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(ColorTokens.textSecondary).offset(x: 5, y: 4).accessibilityHidden(true) }
                    }
                if !state.collapsed {
                    Text(verbatim: name).font(Typography.row).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail); Spacer(minLength: 0)
                    if let count { Text(verbatim: count.formatted()).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true) }
                    if locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true) }
                }
            }
            .padding(.horizontal, state.collapsed ? 0 : 12).frame(height: density.sidebarRowHeight + 2)
            .frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
            .foregroundStyle(selected ? accent : ColorTokens.textSecondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.18), lineWidth: 1))
                        .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 3).padding(.vertical, 10).padding(.leading, 3) }
                        .matchedGeometryEffect(id: "sidebar-selection", in: selectionSlide)
                }
            }
            .animation(BrandMotion.standard, value: state.selection)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(name).atlasCovers("screen.sidebar.folders")                                      // full name for truncated labels
        .accessibilityLabel(name)
        .accessibilityValue([count.map { Localized.plural($0, one: "%@ title", other: "%@ titles") }, locked ? Localized.string("Locked") : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        VStack(spacing: 5) {
            if showsSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
                    TextField("Search folders", text: $folderQuery).textFieldStyle(.plain).font(Typography.caption).atlas("control.sidebar.folderSearch")
                    if !folderQuery.isEmpty {
                        Button { folderQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel(title("Clear folder search")).atlas("control.sidebar.folderSearchClear")
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(ColorTokens.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(ColorTokens.line))
                .accessibilityElement(children: .contain).accessibilityLabel(title("Search sidebar folders"))
            }
            playlistButton
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
        .overlay(alignment: .top) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
        .zIndex(2)
    }

    private var playlistButton: some View {
        Button(action: onTogglePlaylistMenu) {
            HStack(spacing: 7) {
                Circle().fill(state.playlistName == nil ? ColorTokens.textTertiary : ColorTokens.success).frame(width: 6, height: 6)
                if !state.collapsed {
                    Text(verbatim: state.playlistName ?? title("No playlist")).font(Typography.caption).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            .padding(.horizontal, 6).frame(height: 28).frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .help(state.playlistName ?? title("No playlist"))
        .accessibilityLabel(title("Select playlist")).accessibilityValue(state.playlistName ?? title("none")).atlas("control.sidebar.playlistButton")
    }

    /// Opens upward, inside the sidebar's inner width, and scrolls when there are many playlists.
    private var playlistMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playlists").textCase(.uppercase).font(Typography.eyebrow).tracking(1.3).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 8).padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(state.playlists) { p in
                        Button { onSwitchPlaylist(p.id) } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: p.name).font(Typography.row).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if p.id == state.activePlaylistID { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(p.id == state.activePlaylistID ? accent : ColorTokens.textPrimary).contentShape(Rectangle())
                        }
                        .buttonStyle(MenuRowStyle()).accessibilityLabel(p.name).accessibilityAddTraits(p.id == state.activePlaylistID ? .isSelected : []).atlas("control.sidebar.playlistRow")
                        .contextMenu {
                            if let remove = onRemovePlaylist, p.id != AppState.allPlaylistsID { Button("Remove…", role: .destructive) { remove(p.id) }.atlas("control.sidebar.playlistRemove") }
                        }
                    }
                }
            }
            .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ColorTokens.line).padding(.vertical, 3)
            Button(action: onAddPlaylist) {
                HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text(title("Add playlist")).font(Typography.row); Spacer() }
                    .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(MenuRowStyle()).atlas("screen.addPlaylist")
        }
        .padding(5).frame(width: Self.menuWidth(collapsed: state.collapsed)).glass(radius: 9)
        .shadow(color: ColorTokens.background.opacity(0.8), radius: 18, y: 8)
        .accessibilityElement(children: .contain).accessibilityLabel(title("Playlists")).atlas("screen.playlistMenu")
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering && !selected ? ColorTokens.line : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AnimationTokens.hover, value: hovering)
            .animation(AnimationTokens.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}


/// Moves the dragged folder to where it is being held, live, so the list shows the result before the drop.
private struct FolderDropDelegate: DropDelegate {
    let target: SidebarEntry?
    @Binding var working: [SidebarEntry]?
    @Binding var dragging: String?
    @Binding var hovered: String?
    let movable: (SidebarEntry) -> Bool
    /// The folders as they are saved, to start from again when the preview was dropped by leaving the list.
    let restore: () -> [SidebarEntry]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        if working == nil, dragging != nil { working = restore() }
        if let target { hovered = target.id }
        guard let target, let dragging, dragging != target.id, var list = working,
              let from = list.firstIndex(where: { $0.id == dragging }), let to = list.firstIndex(of: target), movable(target) else { return }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        working = list
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let ids = SidebarModel.changedOrder(working, saved: restore()) { commit(ids) }          // a drop that moved nothing saves nothing
        working = nil; dragging = nil; hovered = nil
        return true
    }

    /// Leaving the list (not a row) without dropping: the preview goes back to the saved order and nothing stays marked as held.
    func dropExited(info: DropInfo) {
        guard target == nil else { return }
        working = nil; hovered = nil
    }
}


/// Scrolls a list while something is dragged near its top or bottom edge. It polls the pointer on a timer that also runs while
/// AppKit is tracking a drag, because the drag itself blocks the normal event flow.
@MainActor
final class DragAutoScroller {
    weak var view: NSView?
    private var timer: Timer?
    private var released = 0

    /// `onEnd` runs once when the primary mouse button is up, which is how a drag that ended without a drop (outside the list, or cancelled) is noticed.
    /// It waits for two ticks of a released button, so a normal drop is handled by the drop first.
    func start(onEnd: @escaping @MainActor () -> Void = {}, step: @escaping @MainActor (Int) -> Void) {
        stop()
        released = 0
        let t = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if SidebarModel.dragHasEnded(pressedButtons: NSEvent.pressedMouseButtons) {
                    self.released += 1
                    if self.released >= 2 { self.stop(); onEnd() }
                    return
                }
                self.released = 0
                guard let v = self.view, let w = v.window else { return }
                let frame = w.convertToScreen(v.convert(v.bounds, to: nil))
                let m = NSEvent.mouseLocation
                guard m.x >= frame.minX - 24, m.x <= frame.maxX + 24 else { return }
                let edge: CGFloat = 44
                if m.y > frame.maxY - edge { step(-1) } else if m.y < frame.minY + edge { step(1) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

private struct ViewProbe: NSViewRepresentable {
    let scroller: DragAutoScroller
    func makeNSView(context: Context) -> NSView { let v = NSView(); scroller.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { scroller.view = v }
}
