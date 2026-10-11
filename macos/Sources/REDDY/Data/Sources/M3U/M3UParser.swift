import Foundation

/// Incremental #EXTM3U parser. Feed it bytes in any chunking; it emits entries as they complete.
/// Handles BOMs, CRLF/LF, quoted attributes (including commas inside quotes), missing metadata and oversized lines.
struct M3UStreamParser: Sendable {
    private var buffer = Data()
    private var pending: M3UEntry?
    private var firstLine = true
    private(set) var header = M3UHeader()
    private(set) var skippedLines = 0
    let maxLineBytes: Int

    init(maxLineBytes: Int = 16 * 1024) { self.maxLineBytes = maxLineBytes }

    mutating func feed(_ data: Data, emit: (M3UEntry) -> Void) {
        buffer.append(data)
        var start = 0
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            handle(line: buffer[start..<nl], emit: emit)
            start = nl + 1
        }
        if start > 0 { buffer.removeSubrange(0..<start) }
        // Guard against a single endless line with no newline.
        if buffer.count > maxLineBytes * 4 { buffer.removeAll(); skippedLines += 1 }
    }

    mutating func finish(emit: (M3UEntry) -> Void) {
        if !buffer.isEmpty { handle(line: buffer[...], emit: emit); buffer.removeAll() }
    }

    private mutating func handle(line raw: Data.SubSequence, emit: (M3UEntry) -> Void) {
        guard raw.count <= maxLineBytes else { skippedLines += 1; return }
        var line = String(decoding: raw, as: UTF8.self)
        if firstLine { firstLine = false; if line.hasPrefix("\u{FEFF}") { line.removeFirst() } }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.hasPrefix("#EXTM3U") {
            let attrs = Self.attributes(in: String(line.dropFirst(7)))
            if let e = attrs["url-tvg"] ?? attrs["x-tvg-url"] {
                header.epgURLs = e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        } else if line.hasPrefix("#EXTINF:") {
            pending = Self.parseExtinf(String(line.dropFirst(8)))
        } else if line.hasPrefix("#EXTGRP:") {
            pending?.group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("#") {
            return  // other directives (#EXTVLCOPT, #KODIPROP, ...) are ignored
        } else {
            var entry = pending ?? M3UEntry(name: Self.nameFromURL(line), url: "")
            entry.url = line
            pending = nil
            emit(entry)
        }
    }

    static func nameFromURL(_ s: String) -> String {
        guard let u = URL(string: s) else { return "Stream" }
        let last = u.deletingPathExtension().lastPathComponent
        return last.isEmpty ? (u.host ?? "Stream") : last
    }

    /// `-1 tvg-id="a" group-title="News, World",Channel Name`
    static func parseExtinf(_ body: String) -> M3UEntry {
        let chars = Array(body)
        var i = 0
        var durText = ""
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "," { durText.append(chars[i]); i += 1 }
        var attrs: [String: String] = [:]
        var name = ""
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            if chars[i] == "," { name = String(chars[(i + 1)...]); break }
            var key = ""
            while i < chars.count, chars[i] != "=", chars[i] != ",", !chars[i].isWhitespace { key.append(chars[i]); i += 1 }
            if i < chars.count, chars[i] == "=" {
                i += 1
                var value = ""
                if i < chars.count, chars[i] == "\"" {
                    i += 1
                    while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace, chars[i] != "," { value.append(chars[i]); i += 1 }
                }
                if !key.isEmpty { attrs[key.lowercased()] = value }
            } else if key.isEmpty { i += 1 }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let display = trimmed.isEmpty ? (attrs["tvg-name"] ?? "Unnamed") : trimmed
        return M3UEntry(name: display, url: "", duration: Double(durText) ?? -1, attributes: attrs)
    }

    static func attributes(in s: String) -> [String: String] {
        let e = parseExtinf("-1 " + s + ",x")
        return e.attributes
    }
}
