import Testing
import Foundation
@testable import REDDY

/// The privacy matrix: every surface that can name or count content, judged against one library with locked, hidden and twin folders.
/// Rule (owner): recommendation surfaces use an always-restricted baseline, so they hold even in a session unlocked with the PIN.
@Suite("Privacy matrix") struct PrivacyMatrixTests {
    let m: PrivacyMatrix
    init() throws { m = try PrivacyMatrix(); try m.lock() }

    private func titles(_ items: [LibraryItem]) -> Set<String> { Set(items.map(\.id)) }

    // MARK: folder rows and counts

    @Test func lockedFolderRowShowsNoCount() throws {
        m.session(locked: true)
        let rows = try m.repo.categories(sourceID: m.a.id, kind: .movie, includeHidden: false)
        let locked = try #require(rows.first { $0.id == m.aSecret + "-movie" })
        #expect(locked.itemCount == 0, "a locked folder must not give away how many titles it holds")
        let open = try #require(rows.first { $0.id == m.aOpen + "-movie" })
        #expect(open.itemCount == 2)
    }

    @Test func hiddenFoldersAreNotListed() throws {
        for locked in [true, false] {
            m.session(locked: locked)
            let ids = try m.repo.categories(sourceID: nil, kind: .movie, includeHidden: false).map(\.id)
            #expect(!ids.contains(m.aHidden + "-movie") && !ids.contains(m.bHidden + "-movie"))
        }
    }

    // MARK: genres, years

    @Test func genresAndYearsNeverComeFromRestrictedFolders() throws {
        for locked in [true, false] {
            m.session(locked: locked)
            for kind in [ContentKind.movie, .series] {
                let genres = try m.repo.genres(kind: kind)
                #expect(!genres.contains(PrivacyMatrix.secretGenre) && !genres.contains(PrivacyMatrix.hiddenGenre), "locked=\(locked) \(kind)")
                #expect(genres.contains("Drama"))
                let years = try m.repo.years(kind: kind)
                #expect(!years.contains(PrivacyMatrix.secretYear) && !years.contains(PrivacyMatrix.hiddenYear), "locked=\(locked) \(kind)")
                #expect(years.contains(2015) || years.contains(2010))
            }
        }
    }

    // MARK: search

    @Test func searchHidesLockedAndHiddenFolderTitles() throws {
        m.session(locked: true)
        for term in ["Secret", "Hidden", "Cross"] {
            let hits = try m.search.search(term: term, filters: SearchFilters())
            let bad = Set(hits.map(\.itemID)).intersection([m.id("A:Secret Film"), m.id("A:Secret Show"), m.id("A:Hidden Film"), m.id("B:Hidden Film"), m.id("A:Hidden Show"), m.id("A:Secret Channel"), m.id("A:Cross Title")])
            #expect(bad.isEmpty, "\(term): \(bad.count) restricted hits")
        }
    }

    @Test func hiddenFolderTitlesAreOutOfSearchEvenWhenUnlocked() throws {
        m.session(locked: false)
        let hits = try m.search.search(term: "Hidden", filters: SearchFilters())
        #expect(hits.isEmpty, "owner decision 3: hidden folders are excluded from search")
    }

    @Test func castSearchHidesRestrictedTitles() throws {
        m.session(locked: true)
        let people = PeopleIndex(db: m.db, restriction: m.repo.restriction)
        for t in ["A:Secret Film", "A:Hidden Film", "A:Open Film One"] {
            try people.save(itemID: m.id(t), kind: .movie, sourceID: m.a.id, names: ["Zed Famous"])
        }
        let got = Set(people.hits(term: "famous", kinds: [.movie, .series], sourceID: nil, limit: 20).map(\.itemID))
        #expect(got == [m.id("A:Open Film One")])
    }

    // MARK: recommendations, even in an unlocked session

    @Test func discoverNeverShowsRestrictedTitlesInAnUnlockedSession() throws {
        m.session(locked: false)
        let discover = DiscoverService(catalog: m.repo, history: m.history, people: PeopleIndex(db: m.db))
        let content = try discover.build(sourceID: nil)
        var shown = Set(content.shelves.flatMap(\.items).map(\.id))
        if let hero = content.hero { shown.insert(hero.id) }
        #expect(shown.isDisjoint(with: m.restrictedIDs), "baseline must exclude locked and hidden titles in every session")
        #expect(shown.isDisjoint(with: m.restrictedTwinIDs), "a copy of a title with a restricted copy is restricted too")
        #expect(shown.contains(m.id("A:Open Film One")), "the open library still recommends")
    }
}
