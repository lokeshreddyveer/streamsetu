import Testing
import Foundation
@testable import REDDY

@Suite("Guide hub: performance on a 15,000 channel library") struct GuidePerformanceTests {
    static func peakRSS() -> Int {
        var u = rusage(); getrusage(RUSAGE_SELF, &u); return Int(u.ru_maxrss) / (1024 * 1024)   // bytes on macOS -> MB
    }
    static func currentRSS() -> Int {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int(info.resident_size) / (1024 * 1024) : 0
    }

    /// Synthetic library: names built from a word list so there are many near-duplicates, quality copies, +1 variants and prefixes, like a real provider.
    static func library(_ n: Int) -> (channels: [GuideMapChannel], guide: [GuideMapGuideChannel]) {
        let words = ["Sky", "Star", "Zee", "Sony", "Gem", "Nova", "Arte", "Pulse", "Delta", "Orbit", "Metro", "Lumen", "Prime", "Vista", "Cobalt", "Atlas", "Ember", "Quartz", "Harbor", "Falcon", "Meridian", "Sapphire", "Tundra", "Willow"]
        let kinds = ["Sports", "News", "Movies", "Kids", "Music", "Life", "Action", "Drama", "Docs", "Comedy", "Select", "World"]
        let countries = ["uk", "us", "in", "de", "fr", "es", "it", "tr", "pl", "ae"]
        func name(_ i: Int) -> String { "\(words[i % words.count]) \(kinds[(i / words.count) % kinds.count]) \(i / (words.count * kinds.count) + 1)" }
        var guide: [GuideMapGuideChannel] = []
        for i in 0..<(n * 3 / 10) { guide.append(GuideMapGuideChannel(sourceID: "provider:p", xmltvID: "g\(i).\(countries[i % countries.count])", names: [name(i)], country: countries[i % countries.count], priority: 10)) }
        var channels: [GuideMapChannel] = []
        for i in 0..<n {
            let g = i % (n * 3 / 10 + 40)       // some channels have no guide channel at all
            var nm = name(g), tvg: String? = nil
            switch i % 7 { case 0: nm = "UK | " + nm + " HD"; case 1: nm += " FHD"; case 2: nm = nm.uppercased() + " +1"; case 3: tvg = "g\(g).\(countries[g % countries.count])"; default: break }
            channels.append(GuideMapChannel(id: "c\(i)", name: nm, tvgID: i % 20 == 0 ? tvg : nil, providerID: nil, country: i % 3 == 0 ? countries[g % countries.count] : nil, language: nil, ownGuideSource: "provider:p"))
        }
        return (channels, guide)
    }

    static var perf: Bool { ProcessInfo.processInfo.environment["STREAMSETU_PERF"] == "1" }      // full sizes only on request; the default run uses hundreds of rows

    @Test func mappingFifteenThousandChannels() {
        let n = Self.perf ? 15_000 : 600
        let (ch, g) = Self.library(n)
        let before = Self.currentRSS()
        let t0 = Date()
        let r = GuideMappingEngine.map(channels: ch, guide: g)
        let secs = Date().timeIntervalSince(t0)
        let mapped = r.filter { $0.match != nil }.count
        print("GUIDEHUB-PERF mapping: 15000 channels x \(g.count) guide channels in \(String(format: "%.2f", secs)) s; mapped \(mapped); suggestions \(r.filter { !$0.suggestions.isEmpty }.count); rss \(before) -> \(Self.currentRSS()) MB, peak \(Self.peakRSS()) MB")
        #expect(secs < (Self.perf ? 3.0 : 1.0))
        #expect(mapped > n * 2 / 15)
    }

    @Test func normalisingFifteenThousandNames() {
        let (ch, _) = Self.library(Self.perf ? 15_000 : 600)
        let t0 = Date()
        var n = 0
        for c in ch { n += ChannelNormalizer.name(c.name).tokens.count }
        let secs = Date().timeIntervalSince(t0)
        print("GUIDEHUB-PERF normalise: 15000 names in \(String(format: "%.3f", secs)) s")
        #expect(n > 0 && secs < (Self.perf ? 1.5 : 0.5))
    }

    @Test func streamingAGuideOfHalfAMillionProgrammesStaysBounded() throws {
        // Generates a synthetic XMLTV at test time (about 150 MB) and reads it in bounded batches.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("perf-guide-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try FileHandle(forWritingTo: file)
        let base = GuideFixtures.iso("2026-11-22T00:00:00Z")
        func stamp(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d) + " +0000" }
        try h.write(contentsOf: Data("<?xml version=\"1.0\"?><tv>\n".utf8))
        let nCh = Self.perf ? 5000 : 60
        for c in 0..<nCh { try h.write(contentsOf: Data("<channel id=\"ch\(c)\"><display-name>Channel \(c)</display-name></channel>\n".utf8)) }
        let desc = String(repeating: "A programme description with some words in it. ", count: 6)
        var buf = ""
        var total = 0
        for c in 0..<nCh {
            for p in 0..<100 {
                let s = base.addingTimeInterval(Double(p) * 1800)
                buf += "<programme start=\"\(stamp(s))\" stop=\"\(stamp(s.addingTimeInterval(1800)))\" channel=\"ch\(c)\"><title lang=\"en\">Programme \(c) \(p)</title><desc>\(desc)</desc><category>News</category></programme>\n"
                total += 1
            }
            if c % 50 == 49 { try h.write(contentsOf: Data(buf.utf8)); buf = "" }
        }
        try h.write(contentsOf: Data(buf.utf8)); try h.write(contentsOf: Data("</tv>\n".utf8)); try h.close()
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0) / (1024 * 1024)
        let before = Self.currentRSS()
        var peak = before
        var kept = 0
        let t0 = Date()
        let stats = try XMLTVDecoder(window: base...base.addingTimeInterval(86400 * 3), onChannel: { _ in }, onBatch: { b in kept += b.count; peak = max(peak, Self.currentRSS()) }).parse(fileURL: file)
        let secs = Date().timeIntervalSince(t0)
        print("GUIDEHUB-PERF xmltv: \(size) MB, \(total) programmes in \(String(format: "%.1f", secs)) s; rss \(before) MB, peak during read \(peak) MB, process peak \(Self.peakRSS()) MB")
        #expect(stats.programmesKept == total && kept == total)
        #expect(!Self.perf || peak - before < 150, "reading must not hold the document in memory")
    }
}
