import Foundation

/// The link a film's Share hands out. The page's own id means something only to a graph that already holds the film, so a film that has an id other systems know
/// (TMDB, Wikidata, IMDb) is shared by that id: the app that opens it finds the film or fetches it. With none, the page's own id is the fallback.
enum MusicFilmShare {
    static let preferredSchemes: [ExternalID.Scheme] = [.tmdbMovie, .tmdbTV, .wikidata, .imdbTitle]

    static func url(entity id: MusicEntityID, externalIDs: [ExternalID]) -> URL? {
        for scheme in preferredSchemes {
            guard let x = externalIDs.first(where: { $0.scheme == scheme }), MusicEntityLink.externalID(scheme.rawValue + ":" + x.value) != nil else { continue }
            return MusicDeepLinks.link(entity: .external(id.kind, x))
        }
        return MusicDeepLinks.link(entity: .entity(id, role: nil))
    }
}
