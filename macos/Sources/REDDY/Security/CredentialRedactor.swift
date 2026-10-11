import Foundation

/// Removes logins and tokens from strings before they reach logs, error messages or the UI.
enum CredentialRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            (#"(?i)\b(username|password|pass|pwd|token|key|auth|apikey)=([^&\s"']+)"#, "$1=***"),
            (#"://[^/\s@:]+:[^/\s@]*@"#, "://***@"),
            (#"/(live|movie|series|timeshift)/[^/\s]+/[^/\s]+/"#, "/$1/***/***/"),
        ]
        return defs.compactMap { try? (NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    static func redact(_ text: String) -> String {
        var s = text
        for (re, template) in patterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}
