import SwiftUI

/// Listen Now's sizes by layout class, as plain numbers: tile width, Continue columns, hero height, gaps. The page, the skeletons and the tests read
/// the same table, so a placeholder is always the size of what replaces it. The page margin and the room for the floating bar are not here: they
/// come from `MusicPageColumn` and `MusicLayoutGrid`.
struct MusicHomeLayout: Equatable, Sendable {
    let tileWidth: CGFloat
    let continueColumns: Int
    let heroHeight: CGFloat
    let sectionGap: CGFloat
    let rowArtwork: CGFloat
    /// Wide classes add the album link to a top-track row.
    let rowShowsAlbum: Bool
    /// The hero shows its cover beside the words from this class up.
    let heroShowsCover: Bool

    static func spec(for cls: MusicLayoutClass) -> MusicHomeLayout {
        switch cls {
        case .compact: MusicHomeLayout(tileWidth: 128, continueColumns: 1, heroHeight: 240, sectionGap: MusicSpace.xl, rowArtwork: 44, rowShowsAlbum: false, heroShowsCover: false)
        case .medium: MusicHomeLayout(tileWidth: 150, continueColumns: 2, heroHeight: 260, sectionGap: MusicSpace.xl + MusicSpace.xxs, rowArtwork: 44, rowShowsAlbum: false, heroShowsCover: true)
        case .expanded: MusicHomeLayout(tileWidth: 160, continueColumns: 3, heroHeight: 300, sectionGap: MusicSpace.xxl, rowArtwork: 44, rowShowsAlbum: true, heroShowsCover: true)
        case .wide: MusicHomeLayout(tileWidth: 180, continueColumns: 3, heroHeight: 340, sectionGap: MusicSpace.xxl, rowArtwork: 48, rowShowsAlbum: true, heroShowsCover: true)
        }
    }

    static let heroHeightRange: ClosedRange<CGFloat> = 240...340
    /// The Continue tile: artwork 56 inside a card 8 points larger on each side.
    static let continueArtwork: CGFloat = 56
    static let continueHeight: CGFloat = continueArtwork + MusicSpace.xs * 2
    /// Continue shows up to six tiles.
    static let continueLimit = 6
    static let rowHeight: CGFloat = 60

    /// Rows of the Continue grid for `count` tiles.
    func continueRows(count: Int) -> Int { count <= 0 ? 0 : (count + continueColumns - 1) / continueColumns }
}
