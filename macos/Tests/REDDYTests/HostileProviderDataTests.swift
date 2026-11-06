import Testing
import Foundation
@testable import REDDY

/// What a provider can send is not always what it should: numbers that do not fit an integer, and the same entry twice. None of it may stop the app.
@Suite("Provider data that is not what it should be") struct HostileProviderDataTests {
    private struct Box: Decodable { let v: Flex }
    private func flex(_ json: String) throws -> Flex { try JSONDecoder().decode(Box.self, from: Data("{\"v\": \(json)}".utf8)).v }

    @Test func aNumberTooBigForAnIntegerIsNotACrash() throws {
        #expect(try flex("1e30").string != nil)
        #expect(try flex("1e30").int == nil)
    }

    @Test func textThatIsNotANumberGivesNoInteger() throws {
        #expect(try flex("\"nan\"").int == nil)
        #expect(try flex("\"inf\"").int == nil)
        #expect(try flex("\"1e400\"").int == nil)
    }

    @Test func decimalsAreCutTowardZeroAndWholeNumbersStayWhole() throws {
        #expect(try flex("\"5.7\"").int == 5)
        #expect(try flex("7").int == 7)
        #expect(try flex("\"12\"").int == 12)
    }

    @Test func aDurationTooBigForAnIntegerInSearchIsNotACrash() {
        // "under 1e30 hours" and "under inf hours" typed into search.
        #expect(Int(exactly: (1e30 * 60.0).rounded(.towardZero)) == nil)
        #expect(Int(exactly: (Double.infinity * 60.0).rounded(.towardZero)) == nil)
        #expect(Int(exactly: (1.5 * 60.0).rounded(.towardZero)) == 90)
    }

    @Test func aSeasonListedTwiceKeepsTheFirstName() {
        // The same grouping the series detail uses for season names.
        let named: [(Int, String?)] = [(1, "First"), (1, "Again"), (2, nil)]
        let names = Dictionary(named, uniquingKeysWith: { first, _ in first })
        #expect(names[1] == "First")
        #expect(names.count == 2)
    }
}
