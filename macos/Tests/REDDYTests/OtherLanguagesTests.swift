import Testing
import Foundation
@testable import REDDY

@Suite("Other languages") struct OtherLanguagesTests {
    private let mine = UUID(), twin = UUID(), other = UUID()

    private func movie(_ id: String, _ title: String, year: Int? = nil, folder: String? = nil, source: UUID? = nil, minutes: Double? = nil,
                       rating: String? = nil, provider: String? = nil) -> OtherLanguages.Candidate {
        let src = source ?? mine
        let m = Movie(id: id, sourceID: src, providerID: provider ?? id, title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: nil, posterURL: nil,
                      backdropURL: nil, releaseYear: year, durationSeconds: minutes.map { $0 * 60 }, genre: nil, rating: rating, categoryID: nil, categoryName: folder,
                      streamRef: "\(id).mp4", addedAt: nil, detailFetchedAt: nil)
        return .init(item: .movie(m), folder: folder, playlistID: src)
    }

    private func series(_ id: String, _ title: String) -> OtherLanguages.Candidate {
        let s = Series(id: id, sourceID: mine, providerID: id, title: title, normalizedTitle: MetadataNormalizer.normalize(title), overview: nil, posterURL: nil,
                       backdropURL: nil, genre: nil, releaseYear: nil, rating: nil, categoryID: nil, categoryName: nil, addedAt: nil, lastMetadataRefresh: nil)
        return .init(item: .series(s), folder: nil, playlistID: mine)
    }

    private func info(_ title: String, _ folder: String?) -> [String] {
        let i = OtherLanguages.languageInfo(title: title, folder: folder)
        return [i.language ?? "-", i.dubbed ? "dubbed" : "", i.folderLabel ?? "-"]
    }

    @Test func dubsOfOneFilmGroupByLanguage() {
        let open = movie("1", "Leo (2023) (Tamil) FHD")
        let pool = [movie("2", "Leo 2023 Hindi"), movie("3", "Leo (2023)", folder: "TELUGU | GENERAL"), movie("4", "Leon (1994)")]
        let v = OtherLanguages.versions(of: open, in: pool)
        #expect(v.map(\.title) == ["Tamil", "Hindi", "Telugu"])
        #expect(v.first?.isCurrent == true && v.first?.badge == "FHD" && v.first?.caption == "தமிழ்")
        #expect(v[1].accessibilityLabel == "Hindi")
    }

    @Test func theLanguageComesFromTheFolderWhenTheTitleHasNone() {
        #expect(info("Leo", "ENGLISH | HINDI DUBBED") == ["Hindi", "dubbed", "-"])
        #expect(info("Leo", "DUBBED IN TAMIL") == ["Tamil", "dubbed", "-"])
        #expect(info("Leo", "BANGLA | GENERAL") == ["Bengali", "", "-"])
        #expect(info("Leo", "ENGLISH | ARABIC SUBTITLES") == ["English", "", "-"])
        #expect(info("Leo (Telugu)", "ENGLISH | HINDI DUBBED") == ["Telugu", "", "-"])
        #expect(info("Leo", "INDIAN | GENERAL") == ["-", "", "Indian"])
        #expect(info("Leo", "(MULTI LANGUAGE)") == ["-", "", "Multi language"])
        let v = OtherLanguages.versions(of: movie("1", "Leo (2023)", folder: "ENGLISH | HINDI DUBBED"), in: [movie("2", "Leo (2023)", folder: "ENGLISH | GENERAL")])
        #expect(v.map(\.title) == ["Hindi", "English"] && v[0].caption == "Dubbed" && v[0].accessibilityLabel == "Hindi, dubbed")
    }

    @Test func aTwinIsHiddenEvenWhenItsOriginalIsNotShown() {
        // My playlist has two Hindi copies in different folders; the twin playlist has both too, and they are not shown again.
        let open = movie("1", "Leo (2023)", year: 2023, folder: "TAMIL | GENERAL")
        let pool = [movie("2", "Leo (2023)", year: 2023, folder: "HINDI | GENERAL"), movie("3", "Leo (2023)", year: 2023, folder: "HINDI | 2023"),
                    movie("4", "Leo (2023)", year: 2023, folder: "HINDI | 2023", source: twin), movie("5", "Leo (2023)", year: 2023, folder: "HINDI | GENERAL", source: twin)]
        let v = OtherLanguages.versions(of: open, in: pool)
        #expect(v.map(\.title) == ["Tamil", "Hindi", "Hindi"])
        #expect(v.map(\.caption) == ["தமிழ்", "हिन्दी", "2023"])
    }

    @Test func aTwinFromADuplicatePlaylistIsHidden() {
        let open = movie("1", "Leo (2023)", year: 2023, folder: "TAMIL | GENERAL")
        let pool = [movie("2", "Leo (2023)", year: 2023, folder: "TAMIL | GENERAL", source: twin), movie("3", "Leo (2023)", year: 2023, folder: "HINDI | GENERAL"),
                    movie("4", "Leo (2023)", year: 2023, folder: "HINDI | GENERAL", source: twin)]
        let v = OtherLanguages.versions(of: open, in: pool)
        #expect(v.map(\.title) == ["Tamil", "Hindi"])
        #expect(v.map(\.caption) == ["தமிழ்", "हिन्दी"])
    }

    @Test func noPlaylistIsEverNamedAndCopiesOfOneLanguageAreToldApartByFolderOrLength() {
        let open = movie("1", "Leo 2023 Tamil FHD", folder: "TAMIL | GENERAL", minutes: 164)
        // Another copy in its own folder (here in another playlist): told apart by the folder's own words.
        let v = OtherLanguages.versions(of: open, in: [movie("2", "Leo 2023 Tamil FHD", folder: "TAMIL | 2026", source: other, minutes: 164)])
        #expect(v.map(\.caption) == ["தமிழ்", "2026"])
        // Folders that say nothing more: the quality and running time, then "Version 2".
        let w = OtherLanguages.versions(of: open, in: [movie("3", "Leo 2023 Tamil", folder: "TAMIL", minutes: 150)])
        #expect(w.map(\.caption) == ["தமிழ்", "2h 30m"])
        let x = OtherLanguages.versions(of: movie("5", "Leo 2023 Tamil", folder: "TAMIL"), in: [movie("6", "Leo 2023 Tamil", folder: "TAMIL MOVIES"), movie("7", "Leo 2023 Tamil", folder: "[TAMIL]")])
        #expect(x.map(\.caption) == ["தமிழ்", "Movies", "Version 3"])
        // The same language and quality in the same folder: a duplicate, not shown.
        #expect(OtherLanguages.versions(of: open, in: [movie("4", "Leo 2023 [Tamil] FHD", folder: "TAMIL | GENERAL")]).isEmpty)
    }

    @Test func folderLabelsLoseTheLanguageAndKeepTheirOwnWords() {
        #expect(OtherLanguages.cleanFolder("TELUGU | 2026") == "2026")
        #expect(OtherLanguages.cleanFolder("ENGLISH | FHD 2025") == "FHD 2025")
        #expect(OtherLanguages.cleanFolder("TAMIL | GENERAL") == "General")
        #expect(OtherLanguages.cleanFolder("ENGLISH 1999-2020") == "1999–2020")
        #expect(OtherLanguages.cleanFolder("HINDI DUBBED") == nil)
    }

    @Test func aYearApartMatchesOnlyWithAnotherFactThatAgrees() {
        let open = movie("1", "Pushpa The Rise (2023) Tamil", minutes: 168)
        #expect(OtherLanguages.versions(of: open, in: [movie("2", "Pushpa The Rise (2024) Hindi", minutes: 170)]).count == 2)
        #expect(OtherLanguages.versions(of: open, in: [movie("3", "Pushpa The Rise (2024) Hindi", minutes: 120)]).isEmpty)
        #expect(OtherLanguages.versions(of: open, in: [movie("4", "Pushpa The Rise (2021) Hindi", minutes: 168)]).isEmpty)
        // A very short title needs two facts a year apart.
        let short = movie("5", "Stolen (2023) Tamil", minutes: 100)
        #expect(OtherLanguages.versions(of: short, in: [movie("6", "Stolen (2024) Hindi", minutes: 101)]).isEmpty)
        let rated = movie("9", "Stolen (2023) Tamil", minutes: 100, rating: "6.5")
        #expect(OtherLanguages.versions(of: rated, in: [movie("10", "Stolen (2024) Hindi", minutes: 101, rating: "6.5")]).count == 2)
    }

    @Test func aMissingYearNeedsTwoWordsOrAFact() {
        #expect(OtherLanguages.versions(of: movie("1", "Leo (2023) Tamil"), in: [movie("2", "Leo Hindi")]).isEmpty)
        // A short title needs two facts: the same length and the same rating.
        #expect(OtherLanguages.versions(of: movie("1", "Leo (2023) Tamil", minutes: 164), in: [movie("2", "Leo Hindi", minutes: 165)]).isEmpty)
        #expect(OtherLanguages.versions(of: movie("1", "Leo (2023) Tamil", minutes: 164, rating: "7.2"), in: [movie("2", "Leo Hindi", minutes: 165, rating: "7.2")]).count == 2)
        #expect(OtherLanguages.versions(of: movie("3", "Fast & Furious (2009) Tamil"), in: [movie("4", "The Fast and Furious Hindi")]).count == 2)
    }

    @Test func sequelsAndKindsNeverGroup() {
        #expect(OtherLanguages.versions(of: movie("1", "John Wick (2014) Hindi"), in: [movie("2", "John Wick 2 (2014) Tamil")]).isEmpty)
        let open = series("s1", "Money Heist (Hindi)")
        #expect(OtherLanguages.versions(of: open, in: [movie("2", "Money Heist (Tamil)")]).isEmpty)
        #expect(OtherLanguages.versions(of: open, in: [series("s2", "Money Heist (Tamil)")]).count == 2)
    }

    @Test func thePreferredLanguageComesRightAfterTheOpenOne() {
        let v = OtherLanguages.versions(of: movie("1", "Leo (2023) Tamil"), in: [movie("2", "Leo (2023) Hindi"), movie("3", "Leo (2023) Telugu"), movie("4", "Leo (2023) Kannada")],
                                        preferred: OtherLanguages.preferredName("te"))
        #expect(v.map(\.title) == ["Tamil", "Telugu", "Hindi", "Kannada"])
    }

    @Test func qualityAndYearAreReadFromTheTitle() {
        #expect(OtherLanguages.quality("Leo (2023) HDCAM", nil) == "CAM")
        #expect(OtherLanguages.quality("Leo [UHD]", nil) == "4K")
        #expect(OtherLanguages.year(movie("1", "Leo 2023 Hindi").item) == 2023)
    }

    @Test func theVersionPillNamesTheOpenVersion() {
        #expect(OtherLanguages.versionLabel(title: "Leo (2023) FHD", folder: "ENGLISH | HINDI DUBBED") == "Hindi · Dubbed · FHD")
        #expect(OtherLanguages.versionLabel(title: "Leo (2023) (Tamil) 4K", folder: nil) == "Tamil · 4K")
        #expect(OtherLanguages.versionLabel(title: "Leo (2023)", folder: "INDIAN | GENERAL") == "Indian")
        #expect(OtherLanguages.versionLabel(title: "Leo (2023)", folder: nil) == nil)
    }

    @Test func eachChipOpensItsOwnVersion() {
        // The chip's link carries the version's own item (its id and stream), never the open one's.
        let open = movie("1", "Leo (2023) Tamil"), hindi = movie("2", "Leo (2023) Hindi")
        let v = OtherLanguages.versions(of: open, in: [hindi])
        #expect(v[1].item.id == "2" && !v[1].isCurrent)
        if case .movie(let m) = v[1].item { #expect(m.streamRef == "2.mp4") } else { Issue.record("not a movie") }
    }
}
