import SwiftUI

/// Chooses the screen for the current tab + sidebar selection.
struct ContentRouter: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    /// The folder being viewed, when it is PIN-locked and the app is locked: the content is replaced by an unlock prompt.
    private var lockedFolder: String? {
        guard case .folder(let id) = router.selection, let p = container?.parental, p.isRestricting, p.isLocked(id) else { return nil }
        return state.folderName(id) ?? "This folder"
    }

    var body: some View {
        Group {
            if let name = lockedFolder { LockedFolderView(name: name) } else {
            switch router.tab {
            case .home: HomeScreen()
            case .liveTV: LiveTVScreen()
            case .movies: LibraryScreen(kind: .movie).id(ContentKind.movie)
            case .series: LibraryScreen(kind: .series).id(ContentKind.series)
            case .guide: GuideScreen()
            }
            }
        }
        .id(router.tab)
        .transition(.opacity)
        .animation(AnimationTokens.page, value: router.tab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorTokens.contentBackground)
    }
}
