import SwiftUI

/// The cast as cards: photo, name, character, and a link to the person's page on the actor role. Shows what the graph holds at once and fills in as
/// more arrives; hidden when the film has no cast.
struct MusicFilmCastSection: View {
    let model: MusicFilmGraphModel
    let hub: MusicHub
    var limit = 40
    /// Opens the Cast tab. The Overview shows the first `limit` people; when there are more, a button says how many and goes there.
    var seeAll: (() -> Void)? = nil
    /// The Cast tab shows the lead cast and the supporting cast as two shelves when the billing order is known.
    var grouped = false
    @Environment(\.musicLayoutClass) private var cls

    var body: some View {
        let section = model.section(MusicFilmSectionKey.cast)
        let cast = model.cast
        let width = MusicGraphCardWidth.width(for: cls)
        let detail = MusicFilmWording.disambiguators(cast)
        if grouped {
            let parts = MusicFilmCastRoles.partition(Array(cast.prefix(limit)))
            if let split = MusicFilmCastRoles.split(parts.main) {
                shelf(Localized.string("Lead cast"), split.lead, section.phase, width, detail)
                shelf(Localized.string("Supporting cast"), split.supporting, section.phase, width, detail)
            } else {
                shelf(Localized.string("Cast"), parts.main, section.phase, width, detail)
            }
            ForEach(parts.byAppearance, id: \.0) { a, people in shelf(Self.title(a), people, section.phase, width, detail) }
        } else {
            shelf(Localized.string("Cast"), Array(cast.prefix(limit)), section.phase, width, detail)
            if let seeAll, cast.count > limit {
                Button(action: seeAll) { Text(verbatim: Localized.string("See all %@ people in the cast", "\(cast.count)")) }
                    .musicButton(.secondary, size: .compact).atlas("control.music.filmCastSeeAll")
            }
        }
    }

    static func title(_ a: MusicFilmCastRoles.Appearance) -> String {
        switch a {
        case .voice: Localized.string("Voice cast")
        case .narrator: Localized.string("Narrators")
        case .cameo: Localized.string("Guests and cameos")
        case .child: Localized.string("Child artists")
        }
    }

    private func shelf(_ title: String, _ people: [MusicFilmPersonItem], _ phase: MusicSectionPhase, _ width: CGFloat, _ detail: [MusicEntityID: String]) -> some View {
        MusicGraphShelf(title: title, phase: phase, itemCount: people.count, itemWidth: width, posterAspect: MusicGraphCardMetrics.castAspect, attribution: nil) {
            ForEach(people) { p in
                MusicGraphCastCard(name: p.name, character: p.character, imageRef: p.imageRef, detail: detail[p.person], width: width, entity: p.person) {
                    hub.open(p.person, role: .actor)
                }
            }
        }
    }
}
