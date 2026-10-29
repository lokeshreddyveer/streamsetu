import SwiftUI

/// The iPad's folder column, beside the content: the folders (categories) of Movies, Series or Live TV. Choosing one changes the content next to it; nothing is pushed.
struct IPadFolderColumn: View {
    let title: String
    let categories: [CatalogCategory]
    @Binding var selection: String?
    @Environment(\.container) private var container
    @State private var lockedPick: String?

    var body: some View {
        List {
            row(id: nil, name: "All", locked: false)
            ForEach(categories) { cat in row(id: cat.id, name: cat.name, locked: container?.parental.isLocked(cat.id) == true) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ColorTokens.surface)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12).background(ColorTokens.surface)
        }
        .sheet(isPresented: Binding(get: { lockedPick != nil }, set: { if !$0 { lockedPick = nil } })) { UnlockSheet { selection = lockedPick } }
        .accessibilityLabel("\(title) folders")
    }

    private func row(id: String?, name: String, locked: Bool) -> some View {
        Button {
            if let id, let p = container?.parental, p.isLocked(id), p.isRestricting { lockedPick = id } else { selection = id }
        } label: {
            HStack {
                Text(name).lineLimit(2).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if locked { Image(systemName: "lock").font(.footnote).foregroundStyle(.secondary) }
                if selection == id { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(ColorTokens.accentDefault) }
            }.contentShape(Rectangle())
        }
        .listRowBackground(selection == id ? ColorTokens.accentDefault.opacity(0.16) : Color.clear)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

/// Lets a screen show a button that hides and shows the folder column instead of its own folder menu.
private struct FolderColumnToggleKey: EnvironmentKey { static let defaultValue: Binding<Bool>? = nil }
extension EnvironmentValues { var folderColumn: Binding<Bool>? { get { self[FolderColumnToggleKey.self] } set { self[FolderColumnToggleKey.self] = newValue } } }

/// A folder column beside Movies or Series, whose model it shares with the screen.
struct IPadLibrary: View {
    let kind: ContentKind
    @State private var model: LibraryModel
    @AppStorage private var shown: Bool
    init(kind: ContentKind) {
        self.kind = kind; _model = State(initialValue: LibraryModel(kind: kind)); _shown = AppStorage(wrappedValue: true, "ipad.folders.\(kind == .movie ? "movies" : "series")")
    }
    var body: some View {
        HStack(spacing: 0) {
            if shown {
                IPadFolderColumn(title: kind == .movie ? "Movies" : "Series", categories: model.categories, selection: $model.categoryID).frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            LibraryView(kind: kind, model: model).environment(\.folderColumn, $shown)
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
    }
}

/// A folder column beside Live TV.
struct IPadLiveTV: View {
    @State private var model = LiveTVModel()
    @AppStorage("ipad.folders.live") private var shown = true
    var body: some View {
        HStack(spacing: 0) {
            if shown {
                IPadFolderColumn(title: "Live TV", categories: model.categories, selection: $model.categoryID).frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            LiveTVView(model: model).environment(\.folderColumn, $shown)
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
    }
}

/// The toolbar button that hides and shows the folder column.
struct FolderColumnButton: View {
    @Binding var shown: Bool
    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "sidebar.leading").pillIcon() }.accessibilityLabel(shown ? "Hide folders" : "Show folders")
            .keyboardShortcut("0", modifiers: [.command, .option])
    }
}
