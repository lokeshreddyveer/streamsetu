import Foundation

/// Bounded exponential backoff with jitter. Never retries forever, never retries auth failures.
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 20

    static let standard = RetryPolicy()
    static let none = RetryPolicy(maxAttempts: 1)

    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double = .random(in: 0.5...1.0)) -> TimeInterval {
        if let retryAfter { return min(maxDelay, max(0, retryAfter)) }
        let exp = baseDelay * pow(2, Double(attempt - 1))
        return min(maxDelay, exp) * jitter
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await operation() }
            catch {
                let ne = NetworkError.from(error)
                guard attempt < maxAttempts, ne.isRetryable, !Task.isCancelled else { throw ne }
                var retryAfter: TimeInterval?
                if case .http(_, let r) = ne { retryAfter = r }
                try await Task.sleep(nanoseconds: UInt64(delay(afterAttempt: attempt, retryAfter: retryAfter) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
