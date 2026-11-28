import Foundation
struct MusicKeychain: Sendable {
    static let service = "x"; static let shared = MusicKeychain()
    init(service: String = "x") {}
    func read(_ a: String) -> String? { nil }
    @discardableResult func write(_ a: String, _ v: String?) -> Bool { true }
    func remove(_ a: String) {}
    func readData(_ a: String) -> Data? { nil }
    func writeData(_ a: String, _ d: Data) {}
}
enum StorageService {
    static var applicationSupport: URL { FileManager.default.temporaryDirectory.appendingPathComponent("diag-as", isDirectory: true) }
    static var caches: URL { FileManager.default.temporaryDirectory.appendingPathComponent("diag-c", isDirectory: true) }
}
enum MusicAnalysisCache { static let pinnedBudgetBytes: Int64 = 1 }
enum MusicQuality: String, Codable, CaseIterable, Sendable, Comparable { case low, medium, high, lossless; private var r: Int { switch self { case .low: 0; case .medium: 1; case .high: 2; case .lossless: 3 } }; static func < (a: MusicQuality, b: MusicQuality) -> Bool { a.r < b.r } }
/// Stand-in for the statistics rules the local index only uses to cut a credit line at the first artist.
enum MusicStatsRules { static func leadName(_ line: String) -> String? { let t = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces); return (t?.isEmpty ?? true) ? nil : t } }
/// Stand-in for the catalogue's lyrics hook (the matrix does not load the catalogue).
enum MusicCatalogLyricsHook { static func apply(_ variants: [MusicLyricsQueryVariant], request: MusicLyricsRequest, limit: Int) -> [MusicLyricsQueryVariant] { variants } }
