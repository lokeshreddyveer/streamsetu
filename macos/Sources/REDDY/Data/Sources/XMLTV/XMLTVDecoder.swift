import Foundation

/// XMLTV time stamps: "20260101120000 +0100", "202601011200 -05:00", "20260101120000Z", "20260101120000" (no offset).
/// An offset is authoritative. No offset means UTC unless the source says its times are local to a zone.
enum XMLTVTime {
    static func parse(_ s: String, mode: GuideTimeZoneMode = .automatic) -> Date? {
        let u = Array(s.utf8)
        var i = 0
        while i < u.count, u[i] == 32 { i += 1 }
        var digits = 0
        while i + digits < u.count, u[i + digits] >= 48, u[i + digits] <= 57 { digits += 1 }
        guard digits >= 8, digits <= 14, digits % 2 == 0 else { return nil }
        func n(_ a: Int, _ l: Int) -> Int { (a..<a + l).reduce(0) { $0 * 10 + Int(u[i + $1]) - 48 } }
        let y = n(0, 4), mo = n(4, 2), d = n(6, 2)
        let h = digits >= 10 ? n(8, 2) : 0, mi = digits >= 12 ? n(10, 2) : 0, se = digits >= 14 ? n(12, 2) : 0
        guard y >= 1970, y < 2200, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        // Zone part
        var j = i + digits
        while j < u.count, u[j] == 32 { j += 1 }
        var offset: Int?
        if j < u.count {
            let c = u[j]
            if c == 90 || c == 122 { offset = 0 }                                  // Z
            else if c == 43 || c == 45 {                                           // +hhmm, +hh:mm, +hh
                let sign = c == 45 ? -1 : 1
                var k = j + 1
                var hh = 0, mm = 0, got = 0
                while k < u.count, got < 2, u[k] >= 48, u[k] <= 57 { hh = hh * 10 + Int(u[k]) - 48; k += 1; got += 1 }
                if got == 2 {
                    if k < u.count, u[k] == 58 { k += 1 }
                    var g2 = 0
                    while k < u.count, g2 < 2, u[k] >= 48, u[k] <= 57 { mm = mm * 10 + Int(u[k]) - 48; k += 1; g2 += 1 }
                    if g2 == 0 { mm = 0 }
                    guard hh <= 14, mm < 60 else { return nil }
                    offset = sign * (hh * 3600 + mm * 60)
                }
            } else if u.count - j >= 3 {
                let tail = String(decoding: u[j...], as: UTF8.self).uppercased()
                if tail == "UTC" || tail == "GMT" || tail == "UT" { offset = 0 }
            }
        }
        if let off = offset { return Date(timeIntervalSince1970: TimeInterval(epoch(y, mo, d, h, mi, se) - off)) }
        if case .local(let zoneID) = mode, let tz = TimeZone(identifier: zoneID) {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            // A wall time inside a spring-forward gap is moved forward by Calendar; an ambiguous autumn time takes the first occurrence.
            return cal.date(from: DateComponents(timeZone: tz, year: y, month: mo, day: d, hour: h, minute: mi, second: se))
        }
        return Date(timeIntervalSince1970: TimeInterval(epoch(y, mo, d, h, mi, se)))
    }

    private static func epoch(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ se: Int) -> Int {
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se
    }
}

/// Streaming XMLTV reader (bounded memory: one programme at a time, batches of `batchSize`). Reads language, category, icon, episode number, date and rating, never fetches a DTD or entity,
/// truncates absurdly long text, and counts what it skipped and why so an "empty guide" can be explained. Gzip is handled by the caller (`XMLTVClient`/`GzipInflater`); `XMLTVFileStream` sniffs it too.
final class XMLTVDecoder: NSObject, XMLParserDelegate {
    static let minimumForTruncated = 1000
    static let maxTitle = 300, maxText = 4000, maxName = 300

    private let window: ClosedRange<Date>
    private let mode: GuideTimeZoneMode
    private let limits: GuideLimits
    private let batchSize: Int
    private let onChannel: (GuideChannelRecord) -> Void
    private let onBatch: ([GuideProgramme]) throws -> Void
    private let started = Date()
    private(set) var stats = GuideReadStats()
    private var failure: Error?
    private var sawRoot = false

    private var batch: [GuideProgramme] = []
    private var text = ""
    private var capture: String?
    private var channel: GuideChannelRecord?
    private var inProgramme = false
    private var pChannel = "", pStart: Date?, pStop: Date?, pLang: String?
    private var title = "", subtitle: String?, desc: String?, category: String?, icon: String?, episode: String?, date: String?, rating: String?
    private var episodeSystem = ""
    private var inRating = false
    private var nodeCount = 0

    init(window: ClosedRange<Date>, timeZone: GuideTimeZoneMode = .automatic, limits: GuideLimits = .standard, batchSize: Int = 4000,
         onChannel: @escaping (GuideChannelRecord) -> Void, onBatch: @escaping ([GuideProgramme]) throws -> Void) {
        self.window = window; mode = timeZone; self.limits = limits; self.batchSize = batchSize; self.onChannel = onChannel; self.onBatch = onBatch
    }

    func parse(fileURL: URL) throws -> GuideReadStats {
        guard let stream = InputStream(url: fileURL) else { throw GuideReadError.unreadable }
        let p = XMLParser(stream: stream)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        let ok = p.parse()
        if let failure { throw failure }
        if !ok {
            let code = (p.parserError as NSError?)?.code
            let premature = code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue
            guard premature, stats.programmesKept >= Self.minimumForTruncated else { throw p.parserError ?? GuideReadError.unreadable }
            stats.truncated = true
        }
        guard sawRoot else { throw GuideReadError.notAGuide }
        try flush()
        return stats
    }

    private func flush() throws {
        guard !batch.isEmpty else { return }
        let b = batch; batch.removeAll(keepingCapacity: true)
        try onBatch(b)
    }
    private func abort(_ parser: XMLParser, _ e: Error) { failure = e; parser.abortParsing() }
    private static func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        text = ""
        nodeCount += 1
        if nodeCount & 0x3FFF == 0, Date().timeIntervalSince(started) > limits.maxSeconds { abort(parser, GuideReadError.timedOut); return }
        switch name {
        case "tv": sawRoot = true
        case "channel":
            if let id = a["id"], !id.isEmpty { channel = GuideChannelRecord(id: id, displayNames: []) }
        case "programme":
            inProgramme = true
            pChannel = a["channel"] ?? ""
            pStart = a["start"].flatMap { XMLTVTime.parse($0, mode: mode) }
            pStop = a["stop"].flatMap { XMLTVTime.parse($0, mode: mode) }
            pLang = nil
            title = ""; subtitle = nil; desc = nil; category = nil; icon = nil; episode = nil; date = nil; rating = nil
            stats.programmesSeen += 1
            if stats.programmesSeen > limits.maxProgrammes { abort(parser, GuideReadError.tooManyProgrammes) }
        case "display-name", "title", "sub-title", "desc", "category", "date", "episode-num", "value": capture = name
            if name == "title" || name == "desc", pLang == nil, inProgramme { pLang = a["lang"] }
            if name == "episode-num" { episodeSystem = a["system"] ?? "" }
        case "rating": inRating = true
        case "icon":
            if let src = a["src"], !src.isEmpty {
                if inProgramme { icon = icon ?? src } else if var c = channel { c.icon = c.icon ?? src; channel = c }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil, text.utf8.count < 20_000 { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if capture != nil, text.utf8.count < 20_000 { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "display-name":
            if var c = channel, !value.isEmpty, c.displayNames.count < 8 { c.displayNames.append(Self.cut(value, Self.maxName)); channel = c }
        case "title": if inProgramme, title.isEmpty { title = Self.cut(value, Self.maxTitle) }
        case "sub-title": if inProgramme, subtitle == nil, !value.isEmpty { subtitle = Self.cut(value, Self.maxTitle) }
        case "desc": if inProgramme, desc == nil, !value.isEmpty { desc = Self.cut(value, Self.maxText) }
        case "category": if inProgramme, category == nil, !value.isEmpty { category = Self.cut(value, Self.maxName) }
        case "date": if inProgramme, date == nil, !value.isEmpty { date = Self.cut(value, 16) }
        case "value": if inProgramme, inRating, rating == nil, !value.isEmpty { rating = Self.cut(value, 16) }
        case "rating": inRating = false
        case "episode-num":
            if inProgramme, !value.isEmpty {
                let formatted = episodeSystem == "xmltv_ns" ? Self.episodeLabel(fromNS: value) : value
                if episode == nil || episodeSystem == "xmltv_ns" { episode = Self.cut(formatted, 32) }
            }
        case "channel":
            if let c = channel {
                stats.channels += 1
                if stats.channels > limits.maxChannels { abort(parser, GuideReadError.tooManyChannels) } else { onChannel(c) }
            }
            channel = nil
        case "programme":
            inProgramme = false
            finishProgramme(parser)
        default: break
        }
        if capture == name { capture = nil }
        text = ""
    }

    private func finishProgramme(_ parser: XMLParser) {
        guard let s = pStart, let e = pStop, e > s, !pChannel.isEmpty, !title.isEmpty else { stats.droppedInvalid += 1; return }
        if stats.firstStart == nil || s < stats.firstStart! { stats.firstStart = s }
        if stats.lastStop == nil || e > stats.lastStop! { stats.lastStop = e }
        if e < window.lowerBound { stats.droppedPast += 1; return }
        if s > window.upperBound { stats.droppedFuture += 1; return }
        batch.append(GuideProgramme(channel: pChannel, start: s, stop: e, title: title, subtitle: subtitle, description: desc, category: category, icon: icon,
                                    lang: pLang, episodeNum: episode, date: date, rating: rating))
        stats.programmesKept += 1
        if batch.count >= batchSize { do { try flush() } catch { abort(parser, error) } }
    }

    /// xmltv_ns "1.4.0/2" (zero based season.episode.part) -> "S02E05".
    static func episodeLabel(fromNS v: String) -> String {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { $0.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "" }
        guard parts.count >= 2, let s = Int(parts[0]), let e = Int(parts[1]) else {
            if parts.count >= 2, parts[0].isEmpty, let e = Int(parts[1]) { return "E\(String(format: "%02d", e + 1))" }
            return v
        }
        return "S\(String(format: "%02d", s + 1))E\(String(format: "%02d", e + 1))"
    }
}

/// A guide file on disk (plain or gzip) as a `GuideStream`.
struct XMLTVFileStream: GuideStream {
    let file: URL
    func read(window: ClosedRange<Date>, timeZone: GuideTimeZoneMode, limits: GuideLimits, onChannel: @escaping (GuideChannelRecord) -> Void,
              onBatch: @escaping ([GuideProgramme]) throws -> Void) throws -> GuideReadStats {
        var target = file
        var temp: URL?
        if GzipInflater.isGzip(file) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).xml")
            try GzipInflater.inflate(from: file, to: out, maxOutput: limits.maxUnpackedBytes)
            target = out; temp = out
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        return try XMLTVDecoder(window: window, timeZone: timeZone, limits: limits, onChannel: onChannel, onBatch: onBatch).parse(fileURL: target)
    }
}
