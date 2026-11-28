import SwiftUI

// Sections C and D. C: the soundtrack credits (music directors, composers, lyricists, singers and other contributors), each name a button to that
// person's page with the matching role; a credit the film carries but the song does not is tagged "film credit". D: the cast of the film, as cards
// with photo, actor, character and role, each opening the person page on the actor role. A section with nothing to show is not drawn at all.

struct MusicSoundtrackCreditsSection: View {
    let page: MusicSoundtrackPageModel

    var body: some View {
        let groups = page.creditGroups
        let cast = Array(page.cast.prefix(12))
        switch MusicSoundtrackShelfRule.presentation(phase: page.phase(MusicSoundtrackKey.credits), itemCount: groups.count + (cast.isEmpty ? 0 : 1)) {
        case .hidden: EmptyView()
        case .skeleton:
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                MusicSectionTitle(title: Localized.string("Credits"))
                ForEach(0..<2, id: \.self) { _ in MusicSkeletonBlock(width: nil, height: MusicSpace.xl, corner: MusicCorner.control) }
            }
            .accessibilityLabel(Localized.string("Loading %1$@", Localized.string("Credits")))
        case .cards:
            let total = page.rows.count
            let groupsModel = Self.groupModels(groups, songTotal: total)
            let people = cast.map { MusicCreditsCastRow.Member(id: $0.person.id, name: $0.person.name, character: $0.character) }
            VStack(alignment: .leading, spacing: MusicSpace.lg) {
                MusicSectionTitle(title: Localized.string("Credits"))
                ForEach(groupsModel) { g in
                    MusicCreditsGroupView(group: g) { t in page.hub.open(t.id, role: t.openRole) }
                }
                // The film's cast is its own row of portraits, apart from the crew.
                MusicCreditsCastRow(cast: people) { m in page.hub.open(m.id, role: .actor) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Three groups, in reading order: the music, the words and voices, the film's crew. A group with nobody in it is left out.
    static func groupModels(_ groups: [MusicSoundtrackCreditGroup], songTotal: Int) -> [MusicCreditGroupModel] {
        func credits(_ kinds: Set<MusicSoundtrackCreditKind>) -> [(credit: MusicSoundtrackCredit, roleName: String)] {
            groups.filter { kinds.contains($0.kind) }.flatMap(\.credits).map { ($0, MusicSoundtrackText.roleName($0.role, { Localized.string($0) })) }
        }
        let defs: [(String, String, Set<MusicSoundtrackCreditKind>)] = [
            ("music", Localized.string("Music"), [.musicDirector, .composer]),
            ("voices", Localized.string("Words & voices"), [.lyricist, .singer, .artist]),
            ("crew", Localized.string("Film & production"), [.other]),
        ]
        return defs.compactMap { id, title, kinds in
            let tiles = MusicCreditGroupModel.tiles(credits(kinds), songTotal: songTotal)
            return tiles.isEmpty ? nil : MusicCreditGroupModel(id: id, title: title, tiles: tiles)
        }
    }

}
