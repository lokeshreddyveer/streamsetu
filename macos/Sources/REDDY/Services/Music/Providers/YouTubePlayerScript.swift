import Foundation

// Pure text-processing layer for YouTube's player script (base.js). Nothing here touches the network or runs JavaScript, so it is fully testable
// with a small synthetic script.
//
// NOT VERIFIED AGAINST THE LIVE SCRIPT: this was written from the publicly known shape of the script and has not been run against the real
// base.js. YouTube rewrites that file every few days, so every pattern below is best effort and layered; when all layers miss, callers get
// `playerScriptChanged` and fall back to other audio providers.

enum YouTubePlayerScript {
    // MARK: locating the script

    /// The player hash from the iframe API loader, which mentions `/s/player/<hash>/` with escaped slashes.
    static func playerHash(inIframeAPI text: String) -> String? {
        firstMatch(#"(?:\\?/)s(?:\\?/)player(?:\\?/)([A-Za-z0-9_-]{6,16})(?:\\?/)"#, in: text, group: 1)
    }

    /// The full script path from an embed or watch page (`"jsUrl":"/s/player/.../base.js"`).
    static func scriptPath(inPage text: String) -> String? {
        guard let raw = firstMatch(#""(?:jsUrl|PLAYER_JS_URL)"\s*:\s*"([^"]+base\.js)""#, in: text, group: 1) else { return nil }
        let path = raw.replacingOccurrences(of: "\\/", with: "/")
        return path.hasPrefix("/s/player/") ? path : nil
    }

    static func scriptURL(hash: String) -> URL? {
        guard hash.range(of: "^[A-Za-z0-9_-]{6,16}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_US/base.js")
    }

    static func hash(fromScriptPath path: String) -> String? {
        firstMatch(#"/s/player/([A-Za-z0-9_-]{6,16})/"#, in: path, group: 1)
    }

    // MARK: extraction

    static func signatureTimestamp(in script: String) -> Int? {
        firstMatch(#"(?:signatureTimestamp|sts)\s*:\s*(\d{5})"#, in: script, group: 1).flatMap(Int.init)
    }

    /// JavaScript that defines `__ytsig`, the signature function, together with the helper object it calls (reverse / splice / swap steps).
    static func extractDecipher(from script: String) -> String? {
        let ns = script as NSString
        let arr = Array(script.utf16)
        // Layer 1: the usual `function(a){a=a.split("");Helper.x(a,n);...return a.join("")}`.
        // Layer 2: the same shape with the split result held in another variable or some statements before it.
        let patterns = [
            #"function\s*[\w$]*\s*\(\s*([\w$]+)\s*\)\s*\{\s*\1\s*=\s*\1\s*\.split\(\s*(?:""|'')\s*\)"#,
            #"function\s*[\w$]*\s*\(\s*([\w$]+)\s*\)\s*\{[^{}]{0,60}?\1\s*\.split\(\s*(?:""|'')\s*\)"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
                let param = ns.substring(with: m.range(at: 1))
                let head = ns.substring(with: m.range)
                guard let braceInHead = head.firstIndex(of: "{") else { continue }
                let open = m.range.location + head.utf16.distance(from: head.startIndex, to: braceInHead)
                guard let close = matchClose(arr, open: open) else { continue }
                let body = ns.substring(with: NSRange(location: open, length: close - open + 1))
                guard body.contains("join("), body.utf16.count < 4000 else { continue }
                guard let helperName = firstMatch(#"([A-Za-z_$][\w$]*)\s*\.\s*[A-Za-z_$][\w$]*\(\s*"# + NSRegularExpression.escapedPattern(for: param) + #"\s*[,)]"#, in: body, group: 1),
                      helperName != param,
                      let helper = objectDefinition(named: helperName, in: ns, arr: arr) else { continue }
                return "var \(helperName)=\(helper);var __ytsig=function(\(param))\(body);"
            }
        }
        return nil
    }

    /// JavaScript that defines `__ytn`, the throttling-parameter transform, plus any top-level array constants it reads.
    static func extractNTransform(from script: String) -> String? {
        let ns = script as NSString
        let arr = Array(script.utf16)
        var fnText: String?

        // Layers 1 and 2: the call site that reads the `n` parameter, which names the function directly or through an array.
        let callSites = [
            #"\.get\(\s*"n"\s*\)\s*\)\s*&&\s*\(\s*[\w$]+\s*=\s*([\w$]+)(?:\[(\d+)\])?\(\s*[\w$]+\s*\)"#,
            #"[\w$]+\s*=\s*([\w$]+)(?:\[(\d+)\])?\(\s*[\w$]+\s*\)\s*,\s*[\w$.\[\]]+\.set\(\s*"n""#
        ]
        for pattern in callSites {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)) else { continue }
            var name = ns.substring(with: m.range(at: 1))
            if m.range(at: 2).location != NSNotFound, let index = Int(ns.substring(with: m.range(at: 2))) {
                guard let resolved = arrayElement(named: name, index: index, in: script) else { continue }
                name = resolved
            }
            if let f = functionDefinition(named: name, in: ns, arr: arr) { fnText = f; break }
        }

        // Layer 3: the transform's catch block returns a recognisable marker string; walk back to its function.
        if fnText == nil, let marker = script.range(of: "enhanced_except_") {
            let pos = script.utf16.distance(from: script.utf16.startIndex, to: marker.lowerBound)
            let lo = max(0, pos - 6000)
            let window = ns.substring(with: NSRange(location: lo, length: pos - lo))
            if let re = try? NSRegularExpression(pattern: #"function\s*\(\s*([\w$]+)\s*\)\s*\{"#) {
                let hits = re.matches(in: window, range: NSRange(location: 0, length: (window as NSString).length))
                for m in hits.reversed() {
                    let open = lo + m.range.location + m.range.length - 1
                    if let close = matchClose(arr, open: open), close > pos {
                        fnText = ns.substring(with: NSRange(location: lo + m.range.location, length: close - (lo + m.range.location) + 1))
                        break
                    }
                }
            }
        }

        guard let fn = fnText, fn.contains("return"), fn.utf16.count < 20_000 else { return nil }
        let deps = globalArrayDependencies(of: fn, in: ns, arr: arr)
        return deps.joined() + "var __ytn=\(fn);"
    }

    // MARK: pieces

    /// `name={...}` (object literal) definition; returns the literal text.
    private static func objectDefinition(named name: String, in ns: NSString, arr: [UInt16]) -> String? {
        let pattern = #"(?<![\w$.])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*\{"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            let open = m.range.location + m.range.length - 1
            guard let close = matchClose(arr, open: open), close - open < 3000 else { continue }
            let text = ns.substring(with: NSRange(location: open, length: close - open + 1))
            if text.contains("function") { return text }
        }
        return nil
    }

    /// `name=function(a){...}` or `function name(a){...}`; returns `function(a){...}`.
    private static func functionDefinition(named name: String, in ns: NSString, arr: [UInt16]) -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        let patterns = [#"(?<![\w$.])"# + n + #"\s*=\s*function\s*\(([^)]*)\)\s*\{"#, #"function\s+"# + n + #"\s*\(([^)]*)\)\s*\{"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                let open = m.range.location + m.range.length - 1
                guard let close = matchClose(arr, open: open) else { continue }
                return "function(" + ns.substring(with: m.range(at: 1)) + ")" + ns.substring(with: NSRange(location: open, length: close - open + 1))
            }
        }
        return nil
    }

    /// For `var Ab=[fnA,fnB]` returns the identifier at `index`.
    private static func arrayElement(named name: String, index: Int, in script: String) -> String? {
        let p = #"(?<![\w$.])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*\[([^\]]*)\]"#
        guard let list = firstMatch(p, in: script, group: 1) else { return nil }
        let items = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.indices.contains(index), !items[index].isEmpty else { return nil }
        return items[index]
    }

    private static let jsWords: Set<String> = ["var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "try", "catch", "finally", "throw", "new",
        "typeof", "void", "in", "of", "this", "null", "undefined", "true", "false", "break", "continue", "switch", "case", "default", "delete", "instanceof"]

    /// The transform often reads constant arrays defined at the top of the script. Pull in those definitions (bounded) so it can run on its own.
    private static func globalArrayDependencies(of fn: String, in ns: NSString, arr: [UInt16]) -> [String] {
        guard let tokens = try? NSRegularExpression(pattern: #"(?<![\w$.])[A-Za-z_$][\w$]*"#) else { return [] }
        let fnNS = fn as NSString
        var seen = Set<String>(), out: [String] = []
        for m in tokens.matches(in: fn, range: NSRange(location: 0, length: fnNS.length)) {
            let id = fnNS.substring(with: m.range)
            guard !jsWords.contains(id), seen.insert(id).inserted, out.count < 6 else { continue }
            let e = NSRegularExpression.escapedPattern(for: id)
            if fn.range(of: #"(?:var|let|const)\s+"# + e + #"(?![\w$])"#, options: .regularExpression) != nil { continue }
            if fn.range(of: #"function\s*\([^)]*(?<![\w$])"# + e + #"(?![\w$])[^)]*\)"#, options: .regularExpression) != nil { continue }
            // Anything the function assigns to is a local (`b=a.split(""),c=[...]`), not a global constant.
            if fn.range(of: #"(?<![\w$.])"# + e + #"\s*=(?!=)"#, options: .regularExpression) != nil { continue }
            guard let re = try? NSRegularExpression(pattern: #"(?<![\w$.])var\s+"# + e + #"\s*=\s*\["#),
                  let hit = re.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) else { continue }
            let open = hit.range.location + hit.range.length - 1
            guard let close = matchClose(arr, open: open), close - open < 60_000 else { continue }
            var end = close + 1
            // A string-split constant such as `"a;b;c".split(";")` keeps its suffix.
            let tail = ns.substring(with: NSRange(location: end, length: min(40, ns.length - end)))
            if let r = tail.range(of: #"^\s*\.\s*split\(\s*"[^"]{0,4}"\s*\)"#, options: .regularExpression) { end += tail.utf16.distance(from: tail.startIndex, to: r.upperBound) }
            out.append("var \(id)=" + ns.substring(with: NSRange(location: open, length: end - open)) + ";")
        }
        return out
    }

    // MARK: bracket matching

    /// Index of the bracket closing the one at `open`, ignoring brackets inside strings, template text, comments and regex literals.
    static func matchClose(_ s: [UInt16], open: Int) -> Int? {
        guard s.indices.contains(open) else { return nil }
        func c(_ ch: Unicode.Scalar) -> UInt16 { UInt16(ch.value) }
        let (lb, rb, lp, rp, ls, rs) = (c("{"), c("}"), c("("), c(")"), c("["), c("]"))
        guard [lb, lp, ls].contains(s[open]) else { return nil }
        var depth = 0
        var i = open
        var prev: UInt16 = 0           // last significant character
        let regexAfter = Set("(,=:[!&|?{};+-*%<>~^".unicodeScalars.map { UInt16($0.value) })
        let wordsBeforeRegex: Set<String> = ["return", "typeof", "case", "in", "of", "void", "delete", "throw", "new", "else", "do"]
        func isWordChar(_ x: UInt16) -> Bool { (x >= 48 && x <= 57) || (x >= 65 && x <= 90) || (x >= 97 && x <= 122) || x == 95 || x == 36 }
        func wordEnding(at end: Int) -> String {
            var j = end
            while j >= 0, isWordChar(s[j]) { j -= 1 }
            return String(utf16CodeUnits: Array(s[(j + 1)...end]), count: end - j)
        }
        while i < s.count {
            let ch = s[i]
            if ch == c("\"") || ch == c("'") || ch == c("`") {
                var j = i + 1
                while j < s.count, s[j] != ch { j += (s[j] == c("\\")) ? 2 : 1 }
                i = j + 1; prev = ch; continue
            }
            if ch == c("/"), i + 1 < s.count {
                let nx = s[i + 1]
                if nx == c("/") { while i < s.count, s[i] != 10 { i += 1 }; continue }
                if nx == c("*") {
                    i += 2
                    while i + 1 < s.count, !(s[i] == c("*") && s[i + 1] == c("/")) { i += 1 }
                    i += 2; continue
                }
                var isRegex = prev == 0 || regexAfter.contains(prev)
                if !isRegex, isWordChar(prev) { isRegex = wordsBeforeRegex.contains(wordEnding(at: i - 1 - gapBack(s, i))) }
                if isRegex {
                    var j = i + 1, inClass = false
                    while j < s.count {
                        let x = s[j]
                        if x == c("\\") { j += 2; continue }
                        if x == ls { inClass = true } else if x == rs { inClass = false } else if x == c("/"), !inClass { break } else if x == 10 { return nil }
                        j += 1
                    }
                    i = j + 1; prev = c("/"); continue
                }
            }
            if ch == lb || ch == lp || ch == ls { depth += 1 }
            else if ch == rb || ch == rp || ch == rs { depth -= 1; if depth == 0 { return i } }
            if ch != 32, ch != 9, ch != 10, ch != 13 { prev = ch }
            i += 1
        }
        return nil
    }

    /// Whitespace between the previous token and index `i`; lets a keyword before a `/` be found.
    private static func gapBack(_ s: [UInt16], _ i: Int) -> Int {
        var n = 0
        var j = i - 1
        while j >= 0, s[j] == 32 || s[j] == 9 || s[j] == 10 || s[j] == 13 { n += 1; j -= 1 }
        return n
    }

    // MARK: regex helper

    static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              group < m.numberOfRanges, m.range(at: group).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: group))
    }
}
