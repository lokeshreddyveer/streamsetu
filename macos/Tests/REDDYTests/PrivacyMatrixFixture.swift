import Foundation
@testable import REDDY

/// Two playlists that are twins, with folders that are normal, locked, hidden and the twin of a locked one. Synthetic data only.
/// Every privacy test runs against this one library so each surface is judged by the same facts.
struct PrivacyMatrix {
    let db: DatabaseManager
    let repo: SQLiteCatalogRepository
    let indexer: CatalogIndexer
    let search: SQLiteSearchRepository
    let favorites: SQLiteFavoritesRepository
    let history: SQLiteHistoryRepository
    let a: PlaylistSource
    let b: PlaylistSource

    // Folder ids.
    let aOpen = "A-open", aSecret = "A-secret", aHidden = "A-hidden"
    let bOpen = "B-open", bSecret = "B-secret", bHidden = "B-hidden"

    // Facts that exist only in restricted folders (they must never be seen on any surface).
    static let secretGenre = "Zzsecretgenre", hiddenGenre = "Zzhiddengenre"
    static let secretYear = 1955, hiddenYear = 1944

    /// Title -> id for every movie and series, per playlist ("A:Secret Film").
    private(set) var ids: [String: String] = [:]
    func id(_ key: String) -> String { ids[key] ?? "" }

    init() throws {
        db = try TestSupport.makeDB()
        repo = SQLiteCatalogRepository(db: db)
        indexer = CatalogIndexer(db: db)
        search = SQLiteSearchRepository(db: db, restriction: repo.restriction)
        favorites = SQLiteFavoritesRepository(db: db)
        history = SQLiteHistoryRepository(db: db)
        a = try TestSupport.makeSource(db, name: "Alpha")
        b = try TestSupport.makeSource(db, name: "Beta")
        var table: [String: String] = [:]
        for (src, tag) in [(a, "A"), (b, "B")] {
            let open = "\(tag)-open", secret = "\(tag)-secret", hidden = "\(tag)-hidden"
            func cats(_ kind: ContentKind) -> [CatalogCategory] {
                [(open, "Open Shelf"), (secret, "Secret Shelf"), (hidden, "Hidden Shelf")].enumerated().map { i, c in
                    CatalogCategory(id: "\(c.0)-\(kind.rawValue)", sourceID: src.id, kind: kind, providerID: "\(c.0)-\(kind.rawValue)", name: c.1, sortOrder: i)
                }
            }
            func movie(_ pid: String, _ title: String, folder: String, genre: String, year: Int, age: Double) -> Movie {
                var m = TestSupport.movie(src, pid, title, year: year)
                m.categoryID = "\(folder)-movie"; m.categoryName = folder.hasSuffix("secret") ? "Secret Shelf" : folder.hasSuffix("hidden") ? "Hidden Shelf" : "Open Shelf"
                m.genre = genre; m.rating = "7.5"; m.posterURL = "https://img.example/\(tag)/\(pid).jpg"; m.backdropURL = "https://img.example/\(tag)/\(pid)-b.jpg"
                m.overview = "A synthetic story long enough to be a real synopsis for tests."
                m.addedAt = Date().addingTimeInterval(-age)
                table["\(tag):\(title)"] = m.id
                return m
            }
            func show(_ pid: String, _ title: String, folder: String, genre: String, year: Int, age: Double) -> Series {
                var s = TestSupport.series(src, pid, title)
                s.categoryID = "\(folder)-series"; s.categoryName = folder.hasSuffix("secret") ? "Secret Shelf" : folder.hasSuffix("hidden") ? "Hidden Shelf" : "Open Shelf"
                s.genre = genre; s.releaseYear = year; s.rating = "7.1"; s.posterURL = "https://img.example/\(tag)/\(pid).jpg"; s.backdropURL = "https://img.example/\(tag)/\(pid)-b.jpg"
                s.overview = "A synthetic story long enough to be a real synopsis for tests."
                s.addedAt = Date().addingTimeInterval(-age)
                table["\(tag):\(title)"] = s.id
                return s
            }
            // The restricted titles are the newest, so anything "recently added" would lead with them.
            let movies = [
                movie("m1", "Open Film One", folder: open, genre: "Drama", year: 2010, age: 5000),
                movie("m2", "Shared Twin Film", folder: open, genre: "Drama", year: 2012, age: 6000),
                movie("m3", "Secret Film", folder: secret, genre: Self.secretGenre, year: Self.secretYear, age: 10),
                movie("m4", "Hidden Film", folder: hidden, genre: Self.hiddenGenre, year: Self.hiddenYear, age: 20),
            ]
            // "Cross Title" is in a locked folder of Alpha and an unlocked one of Beta: the copy that is open must not carry it onto a recommendation surface.
            let cross = tag == "A" ? movie("m5", "Cross Title", folder: secret, genre: Self.secretGenre, year: 1999, age: 30)
                                   : movie("m5", "Cross Title", folder: open, genre: "Drama", year: 1999, age: 30)
            // The same film under differently written titles: only the identity rule can see that the open copy is the locked one.
            let voyage = tag == "A" ? movie("m6", "Voyage (2020)", folder: secret, genre: Self.secretGenre, year: 2020, age: 40)
                                    : movie("m6", "Voyage 2020 Hindi", folder: open, genre: "Drama", year: 2020, age: 40)
            try indexer.commitMovies(source: src, categories: cats(.movie), movies: movies + [cross, voyage])
            let shows = [
                show("s1", "Open Show One", folder: open, genre: "Drama", year: 2015, age: 5000),
                show("s2", "Secret Show", folder: secret, genre: Self.secretGenre, year: Self.secretYear, age: 10),
                show("s3", "Hidden Show", folder: hidden, genre: Self.hiddenGenre, year: Self.hiddenYear, age: 20),
            ]
            try indexer.commitSeries(source: src, categories: cats(.series), series: shows)
            var ch = TestSupport.channel(src, "c1", "Secret Channel", cat: nil)
            ch.categoryID = "\(secret)-channel"; ch.categoryName = "Secret Shelf"
            var ch2 = TestSupport.channel(src, "c2", "Open Channel", cat: nil)
            ch2.categoryID = "\(open)-channel"; ch2.categoryName = "Open Shelf"
            try indexer.commitChannels(source: src, categories: [
                CatalogCategory(id: "\(secret)-channel", sourceID: src.id, kind: .channel, providerID: "s", name: "Secret Shelf", sortOrder: 0),
                CatalogCategory(id: "\(open)-channel", sourceID: src.id, kind: .channel, providerID: "o", name: "Open Shelf", sortOrder: 1)], channels: [ch, ch2])
            table["\(tag):Secret Channel"] = ch.id
        }
        ids = table
    }

    /// Locks every "Secret Shelf" of the given playlists (one by one: a lock applies to the folder it was made on) and hides every "Hidden Shelf" folder.
    func lock(_ tags: [String] = ["A"]) throws {
        for t in tags { for k in ["movie", "series", "channel"] { try repo.setCategoryLocked("\(t)-secret-\(k)", true) } }
        for t in ["A", "B"] { for k in ["movie", "series"] { try favorites.hide("\(t)-hidden-\(k)", kind: "category") } }
    }

    /// The two states a person can be in: folders hidden (PIN set, locked), or unlocked with the PIN.
    func session(locked: Bool) { repo.restriction.isActive = locked }

    /// Every id that belongs to restricted content: locked folders of A, hidden folders of both, and the copies of a title that has a restricted copy.
    var restrictedIDs: Set<String> {
        let keys = ["A:Secret Film", "A:Hidden Film", "B:Hidden Film", "A:Cross Title", "A:Voyage (2020)", "A:Secret Show", "A:Hidden Show", "B:Hidden Show", "A:Secret Channel"]
        return Set(keys.map(id))
    }
    /// Copies in an open folder that a recommendation surface must still not show, because another copy of the same title is restricted.
    var restrictedTwinIDs: Set<String> { Set(["B:Cross Title", "B:Secret Film", "B:Secret Show", "B:Voyage 2020 Hindi"].map(id)) }
}
