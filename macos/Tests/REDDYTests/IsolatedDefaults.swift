import Foundation

/// A defaults object that lives only in memory. It never registers a preferences domain or writes a file, so a test using it leaves nothing behind (the system's preferences daemon is never involved).
///
/// A named `UserDefaults(suiteName:)` writes a `.plist` into ~/Library/Preferences, and removing the domain makes the daemon write an empty copy later, whatever the test does to clean up. This avoids
/// all of that. It stands in for `UserDefaults` wherever the code under test takes one.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    override init?(suiteName suitename: String?) { super.init(suiteName: suitename) }
    convenience init() { self.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { lock.withLock { store[defaultName] } }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { if let value { store[defaultName] = value } else { store.removeValue(forKey: defaultName) } } }
    override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func url(forKey defaultName: String) -> URL? { (object(forKey: defaultName) as? String).flatMap(URL.init(string:)) }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { store } }
    override func synchronize() -> Bool { true }
    override func register(defaults registrationDictionary: [String: Any]) { lock.withLock { for (k, v) in registrationDictionary where store[k] == nil { store[k] = v } } }
}

/// Defaults for a test of its own. Nothing is stored on disk, so there is nothing to clean up.
enum IsolatedDefaults {
    /// Kept for tests that check nothing is left in use.
    nonisolated(unsafe) static var live: Set<String> = []
    private static let lock = NSLock()

    static func make(_ tag: String) -> (name: String, defaults: UserDefaults) {
        let name = "mem-\(tag)-\(UUID().uuidString)"
        lock.lock(); live.insert(name); lock.unlock()
        return (name, InMemoryDefaults())
    }

    static func remove(_ name: String, _ d: UserDefaults) { lock.lock(); live.remove(name); lock.unlock() }

    @MainActor static func with<T>(_ tag: String, _ body: @MainActor (UserDefaults) throws -> T) rethrows -> T {
        let (name, d) = make(tag); defer { remove(name, d) }
        return try body(d)
    }

    @MainActor static func with<T>(_ tag: String, _ body: @MainActor (UserDefaults) async throws -> T) async rethrows -> T {
        let (name, d) = make(tag); defer { remove(name, d) }
        return try await body(d)
    }
}
