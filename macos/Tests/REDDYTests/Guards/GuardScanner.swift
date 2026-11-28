import Foundation

/// Source scanning shared by the guard tests: it reads every Swift file under Sources/REDDY, blanks comments (and, when asked, the inside of string
/// literals) while keeping every offset and line number, and finds matching braces. It knows nothing about the app, so it needs no main-actor hop.
enum GuardScanner {
    struct SourceFile {
        let path: String         // relative to Sources/REDDY
        let text: String         // original
        let code: String         // comments blanked, string contents blanked, same length
        let literals: String     // comments blanked, string contents kept, same length
    }

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY", isDirectory: true)
    }

    /// Every .swift file under the given folders of Sources/REDDY (empty list: all of Sources/REDDY).
    static func files(under folders: [String] = []) -> [SourceFile] {
        let root = sourcesRoot
        let bases = folders.isEmpty ? [root] : folders.map { root.appendingPathComponent($0, isDirectory: true) }
        var out: [SourceFile] = []
        for base in bases {
            let urls = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for u in urls where u.pathExtension == "swift" {
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let rel = String(u.path.dropFirst(root.path.count + 1))
                out.append(SourceFile(path: rel, text: text, code: scrub(text, blankStrings: true), literals: scrub(text, blankStrings: false)))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: scrubbing

    /// Comments become spaces; with `blankStrings` the inside of string literals does too (the quotes stay). Newlines are always kept, so offsets and
    /// line numbers match the original. String interpolations are code in the original, but are blanked with their string here.
    static func scrub(_ text: String, blankStrings: Bool) -> String {
        let src = Array(text.utf8)
        var out = src
        var i = 0
        func blank(_ a: Int, _ b: Int) { var k = a; while k < b && k < out.count { if out[k] != 10 { out[k] = 32 }; k += 1 } }
        while i < src.count {
            let c = src[i]
            if c == 47, i + 1 < src.count, src[i + 1] == 47 {                       // //
                var j = i; while j < src.count, src[j] != 10 { j += 1 }
                blank(i, j); i = j
            } else if c == 47, i + 1 < src.count, src[i + 1] == 42 {                // /* */ (nests)
                var depth = 1; var j = i + 2
                while j < src.count, depth > 0 {
                    if src[j] == 47, j + 1 < src.count, src[j + 1] == 42 { depth += 1; j += 2 }
                    else if src[j] == 42, j + 1 < src.count, src[j + 1] == 47 { depth -= 1; j += 2 }
                    else { j += 1 }
                }
                blank(i, j); i = j
            } else if c == 34 || c == 35 {                                          // " or #"
                var hashes = 0; var q = i
                while q < src.count, src[q] == 35 { hashes += 1; q += 1 }
                if q < src.count, src[q] == 34 {
                    let end = stringEnd(src, quote: q, hashes: hashes)
                    if blankStrings { blank(q + 1, max(q + 1, end - 1 - hashes)) }
                    i = end
                } else { i = q == i ? i + 1 : q }
            } else { i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The index just after the closing quote (and hashes) of the string whose opening quote is at `quote`.
    private static func stringEnd(_ s: [UInt8], quote: Int, hashes: Int) -> Int {
        let multi = quote + 2 < s.count && s[quote + 1] == 34 && s[quote + 2] == 34
        var i = quote + (multi ? 3 : 1)
        while i < s.count {
            let c = s[i]
            if c == 92 {                                                             // backslash, then hashes, then ( starts an interpolation
                var k = i + 1; var h = 0
                while h < hashes, k < s.count, s[k] == 35 { k += 1; h += 1 }
                if h == hashes, k < s.count, s[k] == 40 { i = interpolationEnd(s, open: k); continue }
                i = k + 1; continue
            }
            if c == 34 {
                if multi {
                    if i + 2 < s.count, s[i + 1] == 34, s[i + 2] == 34 { return closing(s, after: i + 2, hashes: hashes) ?? i + 3 }
                } else if let e = closing(s, after: i, hashes: hashes) { return e }
            }
            if c == 10, !multi { return i }                                          // unterminated: stop at the line end
            i += 1
        }
        return s.count
    }

    private static func closing(_ s: [UInt8], after q: Int, hashes: Int) -> Int? {
        var k = q + 1; var h = 0
        while h < hashes { guard k < s.count, s[k] == 35 else { return nil }; k += 1; h += 1 }
        return k
    }

    /// The index just after the `)` that closes the interpolation opened at `open`, with nested strings and parentheses skipped.
    private static func interpolationEnd(_ s: [UInt8], open: Int) -> Int {
        var depth = 0; var i = open
        while i < s.count {
            let c = s[i]
            if c == 40 { depth += 1 }
            else if c == 41 { depth -= 1; if depth == 0 { return i + 1 } }
            else if c == 34 { i = stringEnd(s, quote: i, hashes: 0); continue }
            i += 1
        }
        return s.count
    }

    // MARK: structure

    /// The index of the `}` that closes the `{` at `open` in already scrubbed code, or nil.
    static func matchingBrace(_ code: [UInt8], open: Int) -> Int? {
        var depth = 0; var i = open
        while i < code.count {
            if code[i] == 123 { depth += 1 }
            else if code[i] == 125 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    /// The index of the `)` that closes the `(` at `open`, or nil.
    static func matchingParen(_ code: [UInt8], open: Int) -> Int? {
        var depth = 0; var i = open
        while i < code.count {
            if code[i] == 40 { depth += 1 }
            else if code[i] == 41 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    static func lineNumber(of offset: Int, in code: [UInt8]) -> Int {
        var n = 1; var i = 0
        while i < offset && i < code.count { if code[i] == 10 { n += 1 }; i += 1 }
        return n
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 9 || c == 13 }
    static func isIdent(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }

    /// The names of the modifiers chained straight after the closing brace at `close` (`.frame(...)`, `.task(id: x) { ... }`, `.onAppear { ... }`).
    static func modifierChain(_ code: [UInt8], after close: Int) -> [String] {
        var names: [String] = []
        var i = close + 1
        while true {
            while i < code.count, isSpace(code[i]) { i += 1 }
            guard i + 1 < code.count, code[i] == 46, isIdent(code[i + 1]) else { return names }
            i += 1
            let start = i
            while i < code.count, isIdent(code[i]) { i += 1 }
            names.append(String(decoding: code[start..<i], as: UTF8.self))
            var j = i
            while j < code.count, code[j] == 32 { j += 1 }
            if j < code.count, code[j] == 40, let e = matchingParen(code, open: j) { i = e + 1; j = i; while j < code.count, code[j] == 32 { j += 1 } }
            if j < code.count, code[j] == 123, let e = matchingBrace(code, open: j) { i = e + 1 }
        }
    }

    /// The code between the braces with every nested `{ ... }` block removed: only the statements at the top level are left.
    static func topLevelText(_ code: [UInt8], open: Int, close: Int) -> String {
        var out: [UInt8] = []; var depth = 0
        var i = open + 1
        while i < close {
            if code[i] == 123 { depth += 1 }
            else if code[i] == 125 { depth -= 1 }
            else if depth == 0 { out.append(code[i]) }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: allowlists

    /// Checks scan results against a budget per file (safe ones, each with a reason, and known offenders still to fix): more than budgeted fails, and
    /// fewer than budgeted fails too, so a fixed offender is removed from the list and the list only ever shrinks.
    static func overBudget(_ found: [String: Int], allowed: [String: (Int, String)]) -> [String] {
        var problems: [String] = []
        for (file, n) in found.sorted(by: { $0.key < $1.key }) where n > (allowed[file]?.0 ?? 0) {
            problems.append("\(file): \(n) found, \(allowed[file]?.0 ?? 0) allowed")
        }
        return problems
    }

    static func staleEntries(_ found: [String: Int], allowed: [String: (Int, String)]) -> [String] {
        allowed.sorted(by: { $0.key < $1.key }).compactMap { file, a in
            let n = found[file] ?? 0
            return n < a.0 ? "\(file): \(n) found, \(a.0) listed (lower or remove the entry)" : nil
        }
    }
}
