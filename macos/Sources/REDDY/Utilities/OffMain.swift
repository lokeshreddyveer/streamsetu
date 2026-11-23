import Foundation

/// Runs blocking work (a database read) off the calling actor and returns its result: the one spelling of `await Task.detached { ... }.value`.
@discardableResult func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T { await Task.detached(operation: work).value }
