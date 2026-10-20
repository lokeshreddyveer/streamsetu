import Testing
import Foundation
@testable import REDDY

@MainActor @Suite struct KeywordAlertTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func prog(_ id: Int64, _ title: String, in minutes: Double) -> EPGProgram {
        EPGProgram(id: id, sourceID: UUID(), xmltvChannelID: "x", start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 60) * 60), title: title)
    }
    private func service(_ programs: [EPGProgram], scheduled: Box = Box(), defaults: UserDefaults? = nil) -> KeywordAlertService {
        KeywordAlertService(defaults: defaults ?? UserDefaults(suiteName: "kw.\(UUID())")!,
                            search: { term, _ in programs.filter { $0.title.lowercased().contains(term.lowercased()) }.map { (program: $0, channelName: "Sports 1") } },
                            schedule: { p, _ in scheduled.add(p.id); return true })
    }
    final class Box: @unchecked Sendable { private let l = NSLock(); private var ids: [Int64] = []; func add(_ i: Int64) { l.lock(); ids.append(i); l.unlock() }; var all: [Int64] { l.lock(); defer { l.unlock() }; return ids } }

    @Test func aMatchingProgrammeGetsOneReminderAndNotAnother() async {
        let box = Box()
        let s = service([prog(1, "Cricket: India vs Australia", in: 90), prog(2, "News", in: 90)], scheduled: box)
        #expect(s.add("cricket"))
        #expect(await s.scan(now: now) == 1)
        #expect(box.all == [1])
        #expect(await s.scan(now: now) == 0)                      // already announced
        #expect(box.all == [1])
    }

    @Test func tooSoonTooFarAndAlreadyStartedAreLeftAlone() async {
        let box = Box()
        let s = service([prog(1, "Cricket A", in: 1), prog(2, "Cricket B", in: -30), prog(3, "Cricket C", in: 40 * 60), prog(4, "Cricket D", in: 600)], scheduled: box)
        s.add("cricket")
        #expect(await s.scan(now: now) == 1)
        #expect(box.all == [4])
    }

    @Test func wordsAreValidatedAndKept() {
        let d = UserDefaults(suiteName: "kw.\(UUID())")!
        let s = service([], defaults: d)
        #expect(!s.add("a")); #expect(s.add("  Cricket ")); #expect(!s.add("cricket"))
        #expect(KeywordAlertService.maxKeywords == 20)
        #expect(service([], defaults: d).keywords == ["Cricket"])
        s.remove("Cricket")
        #expect(service([], defaults: d).keywords.isEmpty)
    }
}
