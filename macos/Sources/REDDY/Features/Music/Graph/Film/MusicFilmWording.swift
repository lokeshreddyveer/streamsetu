import SwiftUI

/// The words of the film page: reasons, match notes, role names and source credits. The pure code stores typed values; the sentences are made here.
enum MusicFilmWording {
    static func roleTitle(_ r: MusicRole) -> String {
        switch r {
        case .director: Localized.string("Director")
        case .producer: Localized.string("Producer")
        case .screenwriter, .writer: Localized.string("Writer")
        case .musicDirector: Localized.string("Music director")
        case .composer: Localized.string("Composer")
        case .cinematographer: Localized.string("Cinematographer")
        case .editor: Localized.string("Editor")
        default: r.rawValue.capitalized
        }
    }

    /// The label of a crew group: a TMDB department by its own name, else the role.
    static func crewTitle(_ g: MusicFilmCrewItem) -> String { g.department.map(departmentTitle) ?? roleTitle(g.role) }

    static func departmentTitle(_ d: MusicFilmDepartment) -> String {
        switch d {
        case .writing: Localized.string("Writer")
        case .camera: Localized.string("Cinematographer")
        case .editing: Localized.string("Editor")
        case .productionDesign: Localized.string("Production design")
        case .sound: Localized.string("Sound")
        case .costume: Localized.string("Costume design")
        case .visualEffects: Localized.string("Visual effects")
        case .choreography: Localized.string("Choreographer")
        }
    }

    /// The heading a crew group sits under on the Crew tab.
    static func headingTitle(_ h: MusicFilmCrewHeading) -> String {
        switch h {
        case .directing: Localized.string("Directing")
        case .writing: Localized.string("Writing")
        case .production: Localized.string("Production")
        case .camera: Localized.string("Camera")
        case .editing: Localized.string("Editing")
        case .art: Localized.string("Art")
        case .sound: Localized.string("Sound")
        case .costume: Localized.string("Costume")
        case .visualEffects: Localized.string("Visual effects")
        case .choreography: Localized.string("Choreography")
        case .music: Localized.string("Music department")
        case .other: Localized.string("Other crew")
        }
    }

    static func videoKindTitle(_ k: MusicFilmVideoKind) -> String {
        switch k {
        case .trailer: Localized.string("Trailers")
        case .teaser: Localized.string("Teasers")
        case .clip: Localized.string("Clips")
        case .featurette: Localized.string("Featurettes")
        case .behindTheScenes: Localized.string("Behind the scenes")
        }
    }

    /// TMDB's release status in the reader's words; a status this list does not know is shown as TMDB wrote it.
    static func statusTitle(_ s: String) -> String {
        switch s.lowercased() {
        case "released": Localized.string("Released")
        case "in production": Localized.string("In production")
        case "post production": Localized.string("Post production")
        case "planned": Localized.string("Planned")
        case "rumored": Localized.string("Rumored")
        case "canceled", "cancelled": Localized.string("Cancelled")
        default: s
        }
    }

    static func languageFilterTitle(_ f: MusicFilmLanguageFilter) -> String {
        switch f {
        case .all: Localized.string("All")
        case .original: Localized.string("Original")
        case .dub(let l): MusicFilmLanguageNames.name(for: l).isEmpty ? l.uppercased() : MusicFilmLanguageNames.name(for: l)
        }
    }

    /// A budget or box-office figure (TMDB states these in US dollars).
    static func money(_ n: Int) -> String { n.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: Localized.activeCode))) }

    static func joined(_ names: [String]) -> String {
        let f = ListFormatter(); f.locale = Locale(identifier: Localized.activeCode)   // "and" in the app's language
        return f.string(from: names) ?? names.joined(separator: ", ")
    }

    /// One reason as a sentence ("Same director: Raj Kapoor").
    static func reason(_ r: MusicFilmRelationReason) -> String {
        switch r {
        case .director(let n): Localized.string("Same director: %1$@", n)
        case .composer(let n): Localized.string("Same composer: %1$@", n)
        case .cast(let names): Localized.string("With %1$@", joined(names))
        case .sameLanguage(let l): Localized.string("Also in %1$@", MusicFilmLanguageNames.name(for: l))
        case .sameEra(let d): Localized.string("From the %1$@s", String(d))
        case .soundtrack: Localized.string("Has a soundtrack")
        }
    }

    /// The first two reasons on one line; the card's tooltip and VoiceOver carry the same line.
    static func reasonLine(_ reasons: [MusicFilmRelationReason]) -> String? {
        let lines = reasons.prefix(2).map(reason)
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
    }

    /// How an inferred soundtrack match was made ("Matched by title and music director"); nil for a link a source states.
    static func matchNote(_ evidence: [String]) -> String? {
        let words = evidence.compactMap { token -> String? in
            switch token {
            case "title": Localized.string("the title")
            case "composer": Localized.string("the music director")
            case "year": Localized.string("the year")
            case "language": Localized.string("the language")
            case "dub-language": Localized.string("the dub language")
            default: nil
            }
        }
        return words.isEmpty ? nil : Localized.string("Matched by %1$@", joined(words))
    }

    static func editionTitle(_ e: MusicFilmEdition) -> String {
        switch e {
        case .original: Localized.string("Original soundtrack")
        case .extended: Localized.string("Extended edition")
        case .remastered: Localized.string("Remastered edition")
        case .score: Localized.string("Background score")
        case .dubbed: Localized.string("Dubbed edition")
        }
    }

    /// `edition` is nil for an album that is not known to be a film's music (an ordinary album of the composer), so it is not called a soundtrack.
    static func albumCaption(_ a: MusicFilmAlbumItem, edition: MusicFilmEdition?) -> String? {
        var parts: [String] = []
        if let edition { parts.append(editionTitle(edition)) }
        if let f = a.filmName { parts.append(Localized.string("From %1$@", f)) }
        if let y = a.year { parts.append(String(y)) }
        if let d = a.dubLanguage { parts.append(Localized.string("Dubbed in %1$@", MusicFilmLanguageNames.name(for: d))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The credit lines the licences ask for, for the sources named on the page.
    static func attributions(_ names: [String]) -> [String] {
        names.map { n in
            switch n {
            case "TMDB": Localized.string(MetadataMatchService.attribution)
            case "Wikipedia": Localized.string("Text from Wikipedia, available under CC BY-SA.")
            default: Localized.string("Film info from %1$@", n)
            }
        }
    }

    /// "b. 1924" for people whose name appears more than once on the page, so two of one name can be told apart; nil otherwise.
    static func disambiguators(_ people: [MusicFilmPersonItem]) -> [MusicEntityID: String] {
        var ids: [String: Set<MusicEntityID>] = [:]   // distinct people per name: one person with two credits is not two people of one name
        for p in people { ids[MusicGraphText.latin(p.name), default: []].insert(p.person) }
        var out: [MusicEntityID: String] = [:]
        for p in people where (ids[MusicGraphText.latin(p.name)]?.count ?? 0) > 1 { if let y = p.birthYear { out[p.person] = Localized.string("b. %1$@", String(y)) } }
        return out
    }
}
