import SwiftUI
import AppKit

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
    /// New folder order (entry ids) after a drag or a menu move. Nil turns reordering off.
    var onReorder: (([String]) -> Void)?
    var onHideFolder: ((String) -> Void)?
    /// Parental lock: which folders are locked, whether a PIN exists / is entered, and the action to lock or unlock one.
    var lockedFolderIDs: Set<String> = []
    var parentalAvailable = false
    var parentalUnlocked = false
    var onLockFolder: ((String, Bool) -> Void)?
    @State private var working: [SidebarEntry]?
    @State private var dragging: String?
    @State private var hovered: String?
    @State private var scroller = DragAutoScroller()
    @Environment(\.reddyAccent) private var accent
    @Environment(\.reddyDensity) private var density

    private var width: CGFloat { state.collapsed ? LayoutTokens.sidebarCollapsedWidth : LayoutTokens.sidebarWidth }
    private var footerHeight: CGFloat { state.collapsed ? 46 : 84 }
    private var visibleFolders: [SidebarEntry] { working ?? SidebarModel.filter(state.folders, query: folderQuery) }
    private var canReorder: Bool { onReorder != nil && folderQuery.isEmpty }
    private func isMovable(_ e: SidebarEntry) -> Bool { e.selection != .folder(CatalogCategory.uncategorizedID) }

    var body: some View {
        VStack(spacing: 0) {
            head                                            // fixed
            VStack(spacing: 1) { ForEach(state.pinned) { row($0) } }.padding(.horizontal, 8)   // fixed shortcuts
            foldersRegion                                   // the only scrolling region
            footer                                          // fixed
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        // Opens upward from the selector and stays inside the sidebar, so it can never leave the window.
        .overlay(alignment: .bottom) {
            if state.playlistMenuOpen { playlistMenu.padding(.bottom, footerHeight + 4).transition(.opacity) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
        .clipped()
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
            if !state.collapsed { Text(state.title.uppercased()).font(Typography.eyebrow).tracking(1.5).foregroundStyle(ColorTokens.textSecondary) }
            Spacer(minLength: 0)
            Button(action: onToggleCollapse) {
                Image(systemName: "sidebar.left").font(.system(size: 14, weight: .regular)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary)
            .accessibilityLabel(state.collapsed ? "Expand sidebar" : "Collapse sidebar")
        }
        .padding(.horizontal, state.collapsed ? 0 : 14).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
    }

    private var foldersRegion: some View {
        VStack(spacing: 0) {
            if !state.folders.isEmpty {
                Rectangle().fill(ColorTokens.line).frame(height: 1).padding(.horizontal, 8).padding(.top, 5)
                if !state.collapsed {
                    Text(state.folderSectionTitle.uppercased()).font(Typography.eyebrow).tracking(1.3).foregroundStyle(ColorTokens.textTertiary)
                        .padding(.horizontal, 17).padding(.top, 8).padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 1) { ForEach(visibleFolders) { folderRow($0) } }.padding(.horizontal, 8).padding(.bottom, 6)
                            .animation(AnimationTokens.hover, value: visibleFolders.map(\.id))
                    }
                    .background(ViewProbe(scroller: scroller))
                    // While a folder is being dragged, holding it near the top or bottom edge of the list scrolls the list.
                    .onChange(of: dragging) { _, d in
                        if d == nil { scroller.stop(); hovered = nil; return }
                        scroller.start { dir in
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
                .onDrop(of: [.text], delegate: FolderDropDelegate(target: nil, working: $working, dragging: $dragging, hovered: $hovered, movable: isMovable) { ids in onReorder?(ids) })
                .onChange(of: state.folders) { _, _ in working = nil; dragging = nil }
                .frame(maxHeight: .infinity)                // takes whatever is left, and shrinks, so only this region scrolls
                .accessibilityLabel(state.folderSectionTitle)
                if visibleFolders.isEmpty && !folderQuery.isEmpty && !state.collapsed {
                    Text("No matching folders").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 17).padding(.bottom, 6)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// A folder row: the normal row, plus drag-to-reorder and a menu with the same moves for keyboard and trackpad users.
    @ViewBuilder private func folderRow(_ e: SidebarEntry) -> some View {
        if canReorder && isMovable(e) {
            row(e)
                .opacity(dragging == e.id ? 0.45 : 1)
                .onDrag { dragging = e.id; working = state.folders; return NSItemProvider(object: e.id as NSString) }
                .onDrop(of: [.text], delegate: FolderDropDelegate(target: e, working: $working, dragging: $dragging, hovered: $hovered, movable: isMovable) { ids in onReorder?(ids) })
                .contextMenu { folderMenu(e, reorder: true) }
        } else {
            row(e).contextMenu { folderMenu(e, reorder: false) }
        }
    }

    @ViewBuilder private func folderMenu(_ e: SidebarEntry, reorder: Bool) -> some View {
        if reorder {
            Button("Move to Top") { move(e, to: 0) }
            Button("Move Up") { move(e, by: -1) }
            Button("Move Down") { move(e, by: 1) }
            Button("Move to Bottom") { move(e, to: Int.max) }
        }
        if case .folder(let id) = e.selection, id != CatalogCategory.uncategorizedID {
            if reorder, let onHideFolder { Divider(); Button("Hide Folder") { onHideFolder(id) } }
            if parentalAvailable, let onLockFolder {
                if reorder { Divider() }
                if lockedFolderIDs.contains(id) { Button("Unlock Folder") { onLockFolder(id, false) } }
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
        return Button { onSelect(e.selection) } label: {
            HStack(spacing: 9) {
                Image(systemName: e.symbol).font(.system(size: 13, weight: .regular)).frame(width: 18)
                if !state.collapsed {
                    Text(e.title).font(Typography.row).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail); Spacer(minLength: 0)
                    if case .folder(let id) = e.selection, lockedFolderIDs.contains(id) { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel("Locked") }
                }
            }
            .padding(.horizontal, state.collapsed ? 0 : 9).frame(height: density.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
            .foregroundStyle(selected ? accent : ColorTokens.textSecondary)
            .background(selected ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: LayoutTokens.radiusSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(e.title)                                      // full name for truncated labels
        .accessibilityLabel(e.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        VStack(spacing: 5) {
            if !state.collapsed {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
                    TextField("Search folders", text: $folderQuery).textFieldStyle(.plain).font(Typography.caption)
                    if !folderQuery.isEmpty {
                        Button { folderQuery = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).accessibilityLabel("Clear folder search")
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
                .accessibilityElement(children: .contain).accessibilityLabel("Search sidebar folders")
            }
            playlistButton
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
        .overlay(alignment: .top) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
        .zIndex(2)
    }

    private var playlistButton: some View {
        Button(action: onTogglePlaylistMenu) {
            HStack(spacing: 7) {
                Circle().fill(state.playlistName == nil ? ColorTokens.textTertiary : ColorTokens.success).frame(width: 6, height: 6)
                if !state.collapsed {
                    Text(state.playlistName ?? "No playlist").font(Typography.caption).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            .padding(.horizontal, 6).frame(height: 28).frame(maxWidth: .infinity, alignment: state.collapsed ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .help(state.playlistName ?? "No playlist")
        .accessibilityLabel("Select playlist").accessibilityValue(state.playlistName ?? "none")
    }

    /// Opens upward, inside the sidebar's inner width, and scrolls when there are many playlists.
    private var playlistMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PLAYLISTS").font(Typography.eyebrow).tracking(1.3).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 8).padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(state.playlists) { p in
                        Button { onSwitchPlaylist(p.id) } label: {
                            HStack(spacing: 6) {
                                Text(p.name).font(Typography.row).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if p.id == state.activePlaylistID { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(p.id == state.activePlaylistID ? accent : ColorTokens.textPrimary).contentShape(Rectangle())
                        }
                        .buttonStyle(MenuRowStyle()).accessibilityLabel(p.name).accessibilityAddTraits(p.id == state.activePlaylistID ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ColorTokens.line).padding(.vertical, 3)
            Button(action: onAddPlaylist) {
                HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("Add playlist").font(Typography.row); Spacer() }
                    .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(MenuRowStyle())
        }
        .padding(5).frame(width: width - 16).glass(radius: 9)
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .accessibilityElement(children: .contain).accessibilityLabel("Playlists")
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering && !selected ? Color.white.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: LayoutTokens.radiusSmall, style: .continuous))
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
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        if let target { hovered = target.id }
        guard let target, let dragging, dragging != target.id, var list = working,
              let from = list.firstIndex(where: { $0.id == dragging }), let to = list.firstIndex(of: target), movable(target) else { return }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        working = list
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let list = working { commit(list.map(\.id)) }
        working = nil; dragging = nil; hovered = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}


/// Scrolls a list while something is dragged near its top or bottom edge. It polls the pointer on a timer that also runs while
/// AppKit is tracking a drag, because the drag itself blocks the normal event flow.
@MainActor
final class DragAutoScroller {
    weak var view: NSView?
    private var timer: Timer?

    func start(step: @escaping @MainActor (Int) -> Void) {
        stop()
        let t = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = self.view, let w = v.window else { return }
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
