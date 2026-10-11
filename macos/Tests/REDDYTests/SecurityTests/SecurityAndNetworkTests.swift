import Testing
import Foundation
@testable import REDDY

@Suite("Security & network") struct SecurityAndNetworkTests {
    @Test func redactorRemovesLoginsAndTokens() {
        let s = "http://h:8080/get.php?username=bob&password=s3cret&type=m3u http://h/live/bob/s3cret/12.ts http://u:p@h/x token=abc123"
        let r = CredentialRedactor.redact(s)
        for secret in ["bob", "s3cret", "abc123", "u:p"] { #expect(!r.contains(secret), "leaked \(secret)") }
        #expect(r.contains("/live/***/***/"))
    }

    @Test func sourceURLValidation() throws {
        #expect(throws: SourceValidationError.self) { try SourceURLValidator.validateRemote("") }
        #expect(throws: SourceValidationError.self) { try SourceURLValidator.validateRemote("ftp://x/y.m3u") }
        #expect(throws: SourceValidationError.self) { try SourceURLValidator.validateRemote("file:///etc/passwd") }
        #expect(throws: SourceValidationError.self) { try SourceURLValidator.validateRemote("not a url") }
        let v = try SourceURLValidator.validateRemote("http://host:8080/list.m3u?username=a&password=b&token=zzz")
        #expect(!v.display.contains("password=b") && !v.display.contains("zzz"))
        #expect(v.full.contains("password=b"))
        #expect(try SourceURLValidator.validateXtreamServer("host.tld:8080/") == "http://host.tld:8080")
    }

    @Test func secretsNeverReachTheDatabase() async throws {
        let db = try TestSupport.makeDB()
        let creds = InMemoryCredentialStore()
        let mgr = SourceManager(catalog: SQLiteCatalogRepository(db: db), credentials: creds, http: HTTPClient())
        let m3u = try mgr.addM3U(name: "Remote", url: "http://host/list.m3u?username=alice&password=hunter2&token=TOK999")
        let xt = try await mgr.addXtream(name: "Xt", server: "http://xt.example:8080", username: "bobuser", password: "pa55w0rd", verify: false)
        // every text value in every table
        let tables = try db.read { try $0.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'catalog_fts%'") { $0.string(0) } }
        var dump = ""
        for t in tables {
            let cols = try db.read { try $0.query("SELECT name FROM pragma_table_info('\(t)')") { $0.string(0) } }
            for c in cols {
                dump += try db.read { try $0.query("SELECT CAST(\"\(c)\" AS TEXT) FROM \"\(t)\"") { $0.optString(0) ?? "" } }.joined(separator: "\n")
            }
        }
        for secret in ["alice", "hunter2", "TOK999", "bobuser", "pa55w0rd"] { #expect(!dump.contains(secret), "\(secret) found in database") }
        // …but the providers can still get them from the Keychain store
        #expect(try creds.load(ref: try #require(m3u.credentialRef))?.url?.contains("TOK999") == true)
        #expect(try creds.load(ref: try #require(xt.credentialRef))?.password == "pa55w0rd")
        // removing a source removes its secrets
        try mgr.remove(xt.id)
        #expect(try creds.load(ref: xt.credentialRef!) == nil)
    }

    @Test func retryPolicyBackoffIsBoundedAndJittered() {
        let p = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 8)
        #expect(p.delay(afterAttempt: 1, retryAfter: nil, jitter: 1) == 1)
        #expect(p.delay(afterAttempt: 3, retryAfter: nil, jitter: 1) == 4)
        #expect(p.delay(afterAttempt: 10, retryAfter: nil, jitter: 1) == 8)
        #expect(p.delay(afterAttempt: 2, retryAfter: nil, jitter: 0.5) == 1)
        #expect(p.delay(afterAttempt: 1, retryAfter: 3, jitter: 1) == 3, "honours Retry-After")
        #expect(p.delay(afterAttempt: 1, retryAfter: 999, jitter: 1) == 8)
    }

    @Test func retriesOnlyTransientFailuresAndStopsAtTheLimit() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let fast = RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.002)
        let c1 = Counter()
        await #expect(throws: NetworkError.self) { try await fast.run { c1.n += 1; throw NetworkError.http(status: 503, retryAfter: nil) } as Int }
        #expect(c1.n == 3)
        let c2 = Counter()
        await #expect(throws: NetworkError.self) { try await fast.run { c2.n += 1; throw NetworkError.http(status: 401, retryAfter: nil) } as Int }
        #expect(c2.n == 1, "auth failures are never retried")
        let c3 = Counter()
        let v = try await fast.run { c3.n += 1; if c3.n < 2 { throw NetworkError.timeout }; return 42 }
        #expect(v == 42 && c3.n == 2)
    }

    @Test func networkErrorsAreClassified() {
        #expect(NetworkError.from(URLError(.notConnectedToInternet)).errorDescription?.contains("internet") == true)
        #expect(NetworkError.from(URLError(.timedOut)).isRetryable)
        #expect(NetworkError.http(status: 403, retryAfter: nil).isAuthFailure)
        #expect(!NetworkError.http(status: 404, retryAfter: nil).isRetryable)
        #expect(NetworkError.http(status: 404, retryAfter: nil).errorDescription?.contains("404") == true)
    }
}
