import Foundation
import os

/// A value shared between threads, behind one lock. The one place for hand-rolled shared state: the compiler checks `Sendable` for real
/// (no `@unchecked`), so a mutable field cannot be added outside the lock.
final class Locked<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<T>
    init(_ value: T) { state = OSAllocatedUnfairLock(initialState: value) }
    var value: T {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    /// Runs `body` on the value while holding the lock.
    func withLock<R: Sendable>(_ body: @Sendable (inout T) -> R) -> R { state.withLock(body) }
    /// Sets the value and returns the old one.
    func swap(_ new: T) -> T { state.withLock { let old = $0; $0 = new; return old } }
}

typealias LockedBox<T: Sendable> = Locked<T>

/// A switch that is read from other threads and can be flipped once or both ways.
final class OnceFlag: Sendable {
    private let state = Locked(false)
    var value: Bool { get { state.value } set { state.value = newValue } }
    /// True for the first caller only (connection state handlers fire more than once).
    func take() -> Bool { state.withLock { if $0 { return false }; $0 = true; return true } }
    /// Sets the flag and returns whether it was already set.
    func set() { state.value = true }
    /// For a begin/end guard: true when this caller started the work.
    func begin() -> Bool { take() }
    func end() { state.value = false }
}
