import Foundation

struct XMLTVStats: Sendable {
    /// The document ended early but enough complete programmes were read to be useful.
    var truncated = false
    var channels = 0
    var programmesSeen = 0
    var programmesKept = 0
}

/// Streams an XMLTV document from disk. Only programmes inside `window` are kept; everything else is skipped
/// before it is ever allocated as a model object. Malformed programmes are dropped, not fatal.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private let window: ClosedRange<Date>
    private let batchSize: Int
    private let onChannel: (XMLTVChannel) -> Void
    private let onBatch: ([XMLTVProgramme]) throws -> Void
    static let minimumForTruncated = 1000
    private(set) var stats = XMLTVStats()
    private var failure: Error?

    private var batch: [XMLTVProgramme] = []
    private var text = ""
    private var inChannel: XMLTVChannel?
    private var progChannel = "", progStart: Date?, progStop: Date?
    private var inProgramme = false
    private var title = "", subtitle: String?, desc: String?, category: String?, icon: String?
    private var capture: String?

    init(window: ClosedRange<Date>, batchSize: Int = 4000, onChannel: @escaping (XMLTVChannel) -> Void,
         onBatch: @escaping ([XMLTVProgramme]) throws -> Void) {
        self.window = window; self.batchSize = batchSize; self.onChannel = onChannel; self.onBatch = onBatch
    }

    func parse(fileURL: URL) throws -> XMLTVStats {
        guard let stream = InputStream(url: fileURL) else { throw NetworkError.unreadable }
        let p = XMLParser(stream: stream)
        p.delegate = self
        p.shouldResolveExternalEntities = false   // untrusted input: no external entity expansion
        let ok = p.parse()
        if let failure { throw failure }
        if !ok {
            // A guide cut off near its end (common with flaky providers) is usable; any other XML error is not.
            let code = (p.parserError as NSError?)?.code
            let prematureEnd = code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue
            guard prematureEnd, stats.programmesKept >= Self.minimumForTruncated else {
                throw p.parserError ?? NetworkError.unreadable
            }
            stats.truncated = true
        }
        try flush()
        return stats
    }

    private func flush() throws {
        guard !batch.isEmpty else { return }
        let b = batch; batch.removeAll(keepingCapacity: true)
        try onBatch(b)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        text = ""
        switch name {
        case "channel":
            if let id = a["id"], !id.isEmpty { inChannel = XMLTVChannel(id: id, displayNames: [], icon: nil) }
        case "programme":
            inProgramme = true
            progChannel = a["channel"] ?? ""
            progStart = a["start"].flatMap(XMLTVMapper.parseTime)
            progStop = a["stop"].flatMap(XMLTVMapper.parseTime)
            title = ""; subtitle = nil; desc = nil; category = nil; icon = nil
            stats.programmesSeen += 1
        case "display-name", "title", "sub-title", "desc", "category": capture = name
        case "icon":
            if let src = a["src"] {
                if inProgramme { icon = icon ?? src } else if var ch = inChannel { ch.icon = ch.icon ?? src; inChannel = ch }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if capture != nil { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "display-name": if !value.isEmpty { inChannel?.displayNames.append(value) }
        case "title": if inProgramme, title.isEmpty { title = value }
        case "sub-title": if inProgramme, subtitle == nil, !value.isEmpty { subtitle = value }
        case "desc": if inProgramme, desc == nil, !value.isEmpty { desc = value }
        case "category": if inProgramme, category == nil, !value.isEmpty { category = value }
        case "channel":
            if let c = inChannel { stats.channels += 1; onChannel(c) }
            inChannel = nil
        case "programme":
            inProgramme = false
            if let s = progStart, let e = progStop, e > s, !progChannel.isEmpty, !title.isEmpty,
               e >= window.lowerBound, s <= window.upperBound {
                batch.append(XMLTVProgramme(channel: progChannel, start: s, stop: e, title: title, subtitle: subtitle,
                                            description: desc, category: category, icon: icon))
                stats.programmesKept += 1
                if batch.count >= batchSize {
                    do { try flush() } catch { failure = error; parser.abortParsing() }
                }
            }
        default: break
        }
        if capture == name { capture = nil }
        text = ""
    }
}
