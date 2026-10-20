import Foundation
import Observation

/// Words the person wants to hear about ("cricket", "India vs"). A few times an hour, the guide is searched for programmes with those words that have not started yet,
/// and each one found gets a reminder like any other (a notification a minute before it starts). A programme is announced once.
@MainActor @Observable
final class KeywordAlertService {
    typealias Search = @Sendable (_ term: String, _ from: Date) throws -> [(program: EPGProgram, channelName: String)]
    typealias Schedule = @Sendable (_ program: EPGProgram, _ channelName: String) async -> Bool

    private(set) var keywords: [String] = []
    private(set) var lastFound: [String] = []
    private let search: Search
    private let schedule: Schedule
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private let wordsKey = "alerts.keywords", doneKey = "alerts.done"
    static let maxKeywords = 20
    /// How far ahead to look, so a week of guide does not become a week of notifications.
    static let horizon: TimeInterval = 36 * 3600

    init(defaults: UserDefaults, search: @escaping Search, schedule: @escaping Schedule) {
        self.defaults = defaults; self.search = search; self.schedule = schedule
        keywords = defaults.stringArray(forKey: wordsKey) ?? []
    }

    static func clean(_ word: String) -> String { word.trimmingCharacters(in: .whitespacesAndNewlines) }

    @discardableResult
    func add(_ word: String) -> Bool {
        let w = Self.clean(word)
        guard w.count >= 2, keywords.count < Self.maxKeywords, !keywords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return false }
        keywords.append(w); defaults.set(keywords, forKey: wordsKey)
        return true
    }

    func remove(_ word: String) { keywords.removeAll { $0 == word }; defaults.set(keywords, forKey: wordsKey) }

    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(nanoseconds: 20 * 60 * 1_000_000_000)
            }
        }
    }

    /// Looks for new matches now. Returns how many reminders were set.
    @discardableResult
    func scan(now: Date = Date()) async -> Int {
        guard !keywords.isEmpty else { return 0 }
        var done = Set(defaults.stringArray(forKey: doneKey) ?? [])
        var set = 0
        var found: [String] = []
        for word in keywords {
            guard let hits = try? search(word, now) else { continue }
            for hit in hits where hit.program.start > now.addingTimeInterval(120) && hit.program.start < now.addingTimeInterval(Self.horizon) {
                let key = "\(hit.program.id)|\(word.lowercased())"
                guard !done.contains(key) else { continue }
                if await schedule(hit.program, hit.channelName) { done.insert(key); set += 1; found.append("\(hit.program.title) · \(hit.channelName) · \(TimeFormatter.time(hit.program.start))") }
            }
        }
        // Old entries are not kept for ever: the list holds the most recent few hundred.
        if done.count > 400 { done = Set(done.suffix(300)) }
        defaults.set(Array(done), forKey: doneKey)
        if !found.isEmpty { lastFound = found }
        return set
    }
}
