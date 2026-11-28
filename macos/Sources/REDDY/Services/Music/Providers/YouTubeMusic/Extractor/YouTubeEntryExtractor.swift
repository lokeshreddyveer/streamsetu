import Foundation

// Finds, in YouTube's own player script, the two entry points the browser path needs: the call that turns a scrambled signature into a real
// one, and the class whose `get("n")` runs the throttling transform. The player builds a media address in one small place (it creates the
// address object, marks it, then writes the signature back); that place is found by its shape, not by its names, because the names change with
// every player build. The result has the same form as a registry entry, so it passes the same strict checks before it reaches any script.

enum YouTubeEntryExtractor {
    static func entry(fromScript script: String) -> YTMCipherEntry? {
        let id = #"[A-Za-z_$][A-Za-z0-9_$]{0,7}"#
        // new [<ns>.]<Class>(url, true); x.set("alr","yes"); c && (c = <Sig>(a, b, <Pre>(c, d, c)), ...
        let pattern = #"new\s+(?:\w+\.)?("# + id + #")\(\s*\w+\s*,\s*!0\s*\)\s*;\s*\w+\.set\(\s*"alr"\s*,\s*"yes"\s*\)\s*;[^;]{0,40}?\(\s*\w+\s*=\s*("# + id + #")\(\s*(\d{1,6})\s*,\s*(\d{1,6})\s*,"#
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let c1 = Range(m.range(at: 1), in: script), let c2 = Range(m.range(at: 2), in: script),
              let c3 = Range(m.range(at: 3), in: script), let c4 = Range(m.range(at: 4), in: script) else { return nil }
        let cls = String(script[c1]), fn = String(script[c2])
        let sig = "\(fn)(\(script[c3]),\(script[c4]),INPUT)"
        guard YouTubeCipherRegistry.validSig(sig), YouTubeCipherRegistry.validClass(cls) else { return nil }
        return YTMCipherEntry(sig: sig, nClass: cls, sts: YouTubePlayerScript.signatureTimestamp(in: script))
    }
}
