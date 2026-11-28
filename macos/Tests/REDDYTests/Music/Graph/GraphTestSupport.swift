import Foundation
import Testing
@testable import REDDY

/// A settable clock for TTL and eviction tests.
final class GraphTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { t = start }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    var reader: @Sendable () -> Date { { [self] in self.now } }
}

enum GraphTestSupport {
    static func tempDirectory() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("graph-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return u
    }

    static func makeStore(clock: GraphTestClock = GraphTestClock(), limits: MusicGraphLimits = .standard, budget: Duration = MusicTraversal.budget) -> (MusicGraphStore, URL) {
        let dir = tempDirectory().appendingPathComponent("Graph", isDirectory: true)
        return (MusicGraphStore(directory: dir, limits: limits, traversalBudget: budget, clock: clock.reader), dir)
    }

    static func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    static func provider(_ uid: String) -> ExternalID { ExternalID(.provider, uid) }

    static func recording(_ title: String, uid: String, extra: [ExternalID] = []) -> MusicEntityDraft {
        MusicEntityDraft(kind: .recording, name: title, externalIDs: [provider(uid)] + extra)
    }
    static func person(_ name: String, ids: [ExternalID] = []) -> MusicEntityDraft { MusicEntityDraft(kind: .person, name: name, externalIDs: ids) }

    static let mb = MusicProvenance(source: .musicbrainz, license: .cc0)
    static func claim(_ source: MusicSourceID, stated: Bool = false, score: Float? = nil, stance: Stance = .asserts, ref: String? = nil, at: Date = Date()) -> MusicProvenance {
        MusicProvenance(source: source, sourceRef: ref, retrievedAt: at, score: score, evidence: stated ? [MusicProvenance.statedToken] : [], stance: stance)
    }
}
