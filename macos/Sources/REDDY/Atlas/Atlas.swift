import Foundation

/// Every entry Setu knows, built once: what the app already declares in typed form (the settings catalogue, the guide articles, the tabs and the sidebar lists), then the declarations in
/// Atlas/Declarations. A declaration with the same id as an imported entry replaces it.
@MainActor enum Atlas {
    static let declared: [AtlasEntry] = AtlasScreens.all + AtlasSettings.extra + AtlasMenus.all + AtlasShortcuts.all + AtlasControls.all + AtlasContext.all + AtlasGestures.all + AtlasIntents.all + AtlasRecipes.all + AtlasDiagnoses.all + AtlasIOSScreens.all + AtlasIOSSettings.all + AtlasWhatsNew.all + AtlasGuide.all + AtlasMusicScreens.all + AtlasMusicLists.all + AtlasMusicControls.all + AtlasMusicExplore.all + AtlasMusicFilm.all + AtlasMusicFilmPage.all + AtlasMusicPerson.all + AtlasMusicArtistPage.all + AtlasMusicFillScreens.all + AtlasMusicSearch.all + AtlasMusicPlaylistPage.all + AtlasSetu.all + AtlasAppKnowledge.all + AtlasMusicKnowledge.all + AtlasMusicShortcuts.all + AtlasMusicSettings.all + AtlasMusicHelp.all + AtlasMusicLibraryGaps.all + AtlasMusicSoundCloud.all + AtlasMusicRadio.all + AtlasMusicHomeRewrite.all + AtlasMusicContextMenu.all + AtlasMusicPlaylistTools.all + AtlasMusicMarkerFixes.all + AtlasMusicAlbumPage.all + AtlasMusicSidebar.all

    static let entries: [AtlasEntry] = merge(imported: AtlasRegistry.importEntries(), declared: declared)
    static let engine = SetuEngine(entries: entries)

    static func merge(imported: [AtlasEntry], declared: [AtlasEntry]) -> [AtlasEntry] {
        let replaced = Dictionary(declared.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = imported.map { replaced[$0.id] ?? $0 }
        let have = Set(imported.map(\.id))
        var seen = have
        for d in declared where !have.contains(d.id) && seen.insert(d.id).inserted { out.append(d) }
        for i in out.indices { if let extra = AtlasTuning.aliases[out[i].id] { out[i].aliases += extra } }
        for i in out.indices { if let extra = AtlasTuning.indic[out[i].id] { out[i].aliases += extra } }
        for i in out.indices { if let fix = AtlasRefine.table[out[i].id] { fix.apply(to: &out[i]) } }
        return out
    }

    static func entry(_ id: String) -> AtlasEntry? { entries.first { $0.id == id } }
}
