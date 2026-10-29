import XCTest
@testable import StreamSetu

/// Choosing a search result: every kind of result the search can return has an action.
@MainActor final class SearchActivationTests: XCTestCase {
    private let everyDestination: [SearchDestination] = [
        .playChannel(channelID: "c"), .movie(id: "m"), .series(id: "s"), .episode(id: "e", seriesID: "s"), .programme(channelID: "c"),
        .folder(categoryID: "f", kind: .channel), .folder(categoryID: "f", kind: .movie), .folder(categoryID: "f", kind: .series), .collection(id: "x"),
    ]

    func testNothingTheSearchReturnsIsASilentNoOp() {
        for d in everyDestination { XCTAssertNotEqual(d.phoneAction, .unavailable, "\(d)") }
    }

    func testFoldersOpenTheScreenThatShowsTheirKind() {
        XCTAssertEqual(SearchDestination.folder(categoryID: "f", kind: .channel).phoneAction, .showFolder(tab: .live, kind: .channel, categoryID: "f"))
        XCTAssertEqual(SearchDestination.folder(categoryID: "f", kind: .movie).phoneAction, .showFolder(tab: .movies, kind: .movie, categoryID: "f"))
        XCTAssertEqual(SearchDestination.folder(categoryID: "f", kind: .series).phoneAction, .showFolder(tab: .series, kind: .series, categoryID: "f"))
    }

    func testACollectionOpensItsOwnPage() {
        XCTAssertEqual(SearchDestination.collection(id: "x").phoneAction, .showCollection(id: "x"))
    }

    func testAFolderResultSetsThePendingFolderTheScreenTakes() {
        // What SearchView does for a folder result, step by step with the real router.
        let router = IOSRouter()
        if case .showFolder(let tab, let kind, let id) = SearchDestination.folder(categoryID: "news", kind: .channel).phoneAction {
            router.pendingFolder = (kind, id); router.go(tab)
        }
        XCTAssertEqual(router.tab, .live)
        XCTAssertEqual(router.pendingFolder?.id, "news")
        XCTAssertEqual(router.pendingFolder?.kind, .channel)
    }
}
