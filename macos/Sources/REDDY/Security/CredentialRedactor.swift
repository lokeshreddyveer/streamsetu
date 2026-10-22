import Foundation

/// Removes logins and tokens from strings before they reach logs, error messages or the UI.
enum CredentialRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // Any parameter whose name says it is a secret or a login: access_token, refresh_token, api_key, X-Plex-Token, client_secret, sig, signature, session, passwd, user, login...
            (#"(?i)([a-z0-9_.\-]*(?:token|secret|passw(?:or)?d|pwd|pass|api[_-]?key|key|auth|sig|signature|session|sess|username|user|login|credential|ticket|bearer)[a-z0-9_.\-]*)=([^&\s"'#]+)"#, "$1=***"),
            // A secret carried in the path: /token/abc, /key/abc, /auth/abc, /apikey/abc
            (#"(?i)/(token|key|auth|apikey|api[_-]key|secret|session|bearer)/[^/\s?#]+"#, "/$1/***"),
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
