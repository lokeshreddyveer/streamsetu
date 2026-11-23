import Foundation

public struct Exemption: Codable, Sendable, Hashable {
    public var file: String
    public var symbol: String
    public var kind: String          // construct name ("Button") or "iconOnly"
    public var reason: String
    public init(file: String, symbol: String, kind: String, reason: String) { self.file = file; self.symbol = symbol; self.kind = kind; self.reason = reason }
    var key: String { "\(file)|\(symbol)|\(kind)" }
}

public struct ExemptionFile: Codable, Sendable {
    /// The reviewed size. Strict mode fails when `exemptions.count` is above it unless --accept-exemptions rewrites it.
    public var approvedCount: Int
    public var exemptions: [Exemption]
    public init(approvedCount: Int = 0, exemptions: [Exemption] = []) { self.approvedCount = approvedCount; self.exemptions = exemptions }

    public static func load(_ url: URL) throws -> ExemptionFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return ExemptionFile() }
        return try JSONDecoder().decode(ExemptionFile.self, from: Data(contentsOf: url))
    }
    public func save(_ url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (e.encode(self) + Data("\n".utf8)).write(to: url)
    }
    public var shortReasons: [Exemption] { exemptions.filter { $0.reason.trimmingCharacters(in: .whitespaces).count < 8 } }
}
