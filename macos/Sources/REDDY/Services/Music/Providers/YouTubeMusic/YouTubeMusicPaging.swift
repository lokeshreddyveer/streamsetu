import Foundation

// Playlist paging. A bare playlist page holds about 100 rows and each continuation token leads to the next 100, one round trip at a time.
// The token is a small protobuf wrapper whose inner parameters hold a row position, so it can be rewritten to ask for later positions
// at the same time (at most 4 requests in flight). Only the exact known token shape is rewritten; anything else, and the first page that
// fails to join cleanly, switches to one-token-at-a-time paging for the rest of the process. The token layout is copied from public
// behaviour and has not been checked against the live service.

enum YTMProto {
    struct Field: Equatable { var number: Int; var varint: UInt64? = nil; var bytes: [UInt8]? = nil }

    static func parse(_ data: [UInt8]) -> [Field]? {
        var out: [Field] = []; var i = 0
        func readVarint() -> UInt64? {
            var v: UInt64 = 0; var shift: UInt64 = 0
            while i < data.count, shift < 64 {
                let b = data[i]; i += 1
                v |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < data.count {
            guard let key = readVarint() else { return nil }
            let number = Int(key >> 3), wire = key & 7
            switch wire {
            case 0: guard let v = readVarint() else { return nil }; out.append(Field(number: number, varint: v))
            case 2:
                guard let len = readVarint(), len <= UInt64(data.count - i) else { return nil }
                out.append(Field(number: number, bytes: Array(data[i..<(i + Int(len))]))); i += Int(len)
            default: return nil
            }
        }
        return out
    }

    static func encode(_ fields: [Field]) -> [UInt8] {
        var out: [UInt8] = []
        func put(_ v: UInt64) { var v = v; while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }; out.append(UInt8(v)) }
        for f in fields {
            if let v = f.varint { put(UInt64(f.number) << 3); put(v) }
            else if let b = f.bytes { put(UInt64(f.number) << 3 | 2); put(UInt64(b.count)); out += b }
        }
        return out
    }
}

/// A base64 text and how it was written, so a rewritten value can be written the same way.
struct YTMB64Style: Equatable {
    var percent = false, urlSafe = false, padded = true

    static func decode(_ s: String) -> (bytes: [UInt8], style: YTMB64Style)? {
        var style = YTMB64Style()
        var t = s
        if t.contains("%") { guard let d = t.removingPercentEncoding else { return nil }; t = d; style.percent = true }
        style.urlSafe = t.contains("-") || t.contains("_")
        style.padded = t.hasSuffix("=")
        var std = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while std.count % 4 != 0 { std += "=" }
        guard let d = Data(base64Encoded: std) else { return nil }
        return ([UInt8](d), style)
    }

    func encode(_ bytes: [UInt8]) -> String {
        var s = Data(bytes).base64EncodedString()
        if urlSafe { s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if !padded { s = s.replacingOccurrences(of: "=", with: "") }
        return percent ? YouTubeSignature.encode(s) : s
    }
}

struct YTMPlaylistToken {
    static let outerField = 80226972
    private var inner: [YTMProto.Field]
    private var outerStyle: YTMB64Style
    private var paramsFields: [YTMProto.Field]
    private var paramsStyle: YTMB64Style
    private var ptFields: [YTMProto.Field]
    let position: Int

    init?(_ token: String) {
        guard let (outerBytes, oStyle) = YTMB64Style.decode(token), let outer = YTMProto.parse(outerBytes),
              outer.count == 1, outer[0].number == Self.outerField, let innerBytes = outer[0].bytes,
              let inner = YTMProto.parse(innerBytes), Set(inner.map(\.number)) == [2, 3, 35],
              let paramsField = inner.first(where: { $0.number == 3 }), let paramsText = paramsField.bytes.flatMap({ String(bytes: $0, encoding: .utf8) }),
              let (pBytes, pStyle) = YTMB64Style.decode(paramsText), let params = YTMProto.parse(pBytes),
              let pt = params.first(where: { $0.number == 15 })?.bytes.flatMap({ String(bytes: $0, encoding: .utf8) }), pt.hasPrefix("PT:"),
              let (ptBytes, _) = YTMB64Style.decode(String(pt.dropFirst(3))), let ptFields = YTMProto.parse(ptBytes),
              let pos = ptFields.first(where: { $0.number == 1 })?.varint else { return nil }
        self.inner = inner; self.outerStyle = oStyle; self.paramsFields = params; self.paramsStyle = pStyle; self.ptFields = ptFields; self.position = Int(pos)
    }

    /// The same token pointing at another row position, with the anchor row dropped.
    func rewritten(position newPos: Int) -> String {
        var pt = ptFields.filter { $0.number != 4 && $0.number != 1 }
        pt.insert(YTMProto.Field(number: 1, varint: UInt64(newPos)), at: 0)
        let ptText = "PT:" + YTMB64Style(percent: false, urlSafe: true, padded: false).encode(YTMProto.encode(pt))
        let params = paramsFields.map { $0.number == 15 ? YTMProto.Field(number: 15, bytes: Array(ptText.utf8)) : $0 }
        let paramsText = paramsStyle.encode(YTMProto.encode(params))
        let newInner = inner.map { $0.number == 3 ? YTMProto.Field(number: 3, bytes: Array(paramsText.utf8)) : $0 }
        return outerStyle.encode(YTMProto.encode([YTMProto.Field(number: Self.outerField, bytes: YTMProto.encode(newInner))]))
    }
}

/// Remembers, for this process, that parallel paging failed to join and must not be tried again.
actor YTMPagingState {
    private(set) var parallelAllowed = true
    func disableParallel() { parallelAllowed = false }
}

enum YTMPlaylistJoin {
    struct Page { var start: Int; var rows: [YTMRow]; var nextToken: String?; var nextPosition: Int? }

    static func key(_ r: YTMRow) -> String { r.setVideoID ?? r.track.id }

    /// Appends `page` to `acc` when it lines up with what is already there. `prevEnd` is where the previous page says it ended.
    static func join(_ acc: inout [YTMRow], prevEnd: Int, page: Page) -> Bool {
        guard prevEnd >= page.start, !page.rows.isEmpty, let end = page.nextPosition ?? (page.nextToken == nil ? page.start + page.rows.count : nil),
              end >= page.start + page.rows.count else { return false }
        let accKeys = acc.map(key), pageKeys = page.rows.map(key)
        var overlap = 0
        for k in stride(from: min(accKeys.count, pageKeys.count), through: 1, by: -1) where Array(accKeys.suffix(k)) == Array(pageKeys.prefix(k)) { overlap = k; break }
        guard overlap > 0 || prevEnd == page.start else { return false }
        let fresh = Array(page.rows.dropFirst(overlap))
        let seen = Set(accKeys)
        guard !fresh.contains(where: { seen.contains(key($0)) }), Set(fresh.map(key)).count == fresh.count else { return false }
        acc += fresh
        return true
    }
}

extension YouTubeMusicClient {
    private func fetchPlaylistPage(_ token: String, start: Int) async -> YTMPlaylistJoin.Page? {
        guard let r = try? await browseContinuation(token) else { return nil }
        let p = YTMPageParser.parsePlaylistContinuation(r.root)
        return YTMPlaylistJoin.Page(start: start, rows: p.rows, nextToken: p.next, nextPosition: p.next.flatMap(YTMPlaylistToken.init)?.position)
    }

    /// All rows of a playlist after the first page. `total` (the header's track count) enables parallel paging.
    func remainingPlaylistRows(firstRows: [YTMRow], token firstToken: String?, total: Int?, state: YTMPagingState, maxPages: Int = 60) async throws -> [YTMRow] {
        var acc = firstRows
        var token = firstToken
        var pages = 0
        while let tok = token, pages < maxPages {
            pages += 1
            if await state.parallelAllowed, let total, let t = YTMPlaylistToken(tok), t.position < total {
                let starts = (1...3).map { t.position + 100 * $0 }.filter { $0 < total }
                let extraTokens = starts.map { ($0, t.rewritten(position: $0)) }
                async let real = fetchPlaylistPage(tok, start: t.position)
                var extras: [YTMPlaylistJoin.Page?] = []
                await withTaskGroup(of: (Int, YTMPlaylistJoin.Page?).self) { g in
                    for (i, e) in extraTokens.enumerated() { g.addTask { (i, await self.fetchPlaylistPage(e.1, start: e.0)) } }
                    var tmp = [YTMPlaylistJoin.Page?](repeating: nil, count: extraTokens.count)
                    for await (i, p) in g { tmp[i] = p }
                    extras = tmp
                }
                guard let first = await real, !first.rows.isEmpty else { return acc }
                acc += first.rows
                token = first.nextToken
                var prevEnd = first.nextPosition ?? (t.position + first.rows.count)
                var joinedAll = true
                for e in extras {
                    guard let e, YTMPlaylistJoin.join(&acc, prevEnd: prevEnd, page: e) else { joinedAll = false; break }
                    prevEnd = e.nextPosition ?? prevEnd; token = e.nextToken
                }
                if !joinedAll { await state.disableParallel() }
            } else {
                guard let r = try? await browseContinuation(tok) else { return acc }
                let p = YTMPageParser.parsePlaylistContinuation(r.root)
                if p.rows.isEmpty { return acc }
                acc += p.rows
                token = p.next == tok ? nil : p.next
            }
        }
        return acc
    }

    /// Library grids: follow up to 20 more pages, drop duplicates by id, keep what loaded if a later page fails, stop on a page with no cards.
    func libraryGrid(_ browseID: String) async throws -> [MusicBrowseItem] {
        guard await isSignedIn else { throw MusicError.notSignedIn("YouTube Music") }
        var first = try await browse(browseID)
        var items: [MusicBrowseItem] = []
        var seen = Set<String>()
        var used = Set<String>()
        for page in 0...20 {
            let parsed = YTMPageParser.parseLibraryGrid(first.root)
            if parsed.items.isEmpty { break }
            for i in parsed.items where seen.insert(YTMItems.key(i)).inserted { items.append(i) }
            guard page < 20, let t = parsed.next, used.insert(t).inserted else { break }
            guard let nextResp = try? await browseContinuation(t) else { break }
            first = nextResp
        }
        return items
    }
}
