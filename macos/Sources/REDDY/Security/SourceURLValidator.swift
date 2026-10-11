import Foundation

enum SourceValidationError: LocalizedError, Sendable {
    case empty, invalid, unsupportedScheme, tooLong, fileMissing, fileTooLarge

    var errorDescription: String? {
        switch self {
        case .empty: "Enter an address."
        case .invalid: "That doesn't look like a valid address."
        case .unsupportedScheme: "Only http and https addresses are supported."
        case .tooLong: "The address is too long."
        case .fileMissing: "That file could not be found."
        case .fileTooLarge: "That file is too large to import."
        }
    }
}

enum SourceURLValidator {
    static let maxURLLength = 4096
    static let maxLocalFileBytes: Int64 = 200 * 1024 * 1024

    /// Validates a remote playlist URL and splits it into a display-safe URL plus the full secret URL.
    static func validateRemote(_ raw: String) throws -> (display: String, full: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SourceValidationError.empty }
        guard t.count <= maxURLLength else { throw SourceValidationError.tooLong }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty
        else { throw SourceValidationError.invalid }
        guard scheme == "http" || scheme == "https" else { throw SourceValidationError.unsupportedScheme }
        let display = CredentialRedactor.redact("\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "") + c.path)
        return (display, t)
    }

    static func validateXtreamServer(_ raw: String) throws -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { throw SourceValidationError.empty }
        guard let base = URLUtilities.normalizeBase(raw) else { throw SourceValidationError.invalid }
        return base
    }

    /// A single stream address: any scheme the players open, not only web addresses.
    static func validateStream(_ raw: String) throws -> (full: String, display: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SourceValidationError.empty }
        guard t.count <= 4096, let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else { throw SourceValidationError.invalid }
        guard playableSchemes.contains(scheme) else { throw SourceValidationError.unsupportedScheme }
        return (t, CredentialRedactor.redact("\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "") + c.path))
    }

    static func validateLocalFile(_ url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw SourceValidationError.fileMissing }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size <= maxLocalFileBytes else { throw SourceValidationError.fileTooLarge }
    }

    /// Schemes the playback engines (MPV, built on FFmpeg) open. Everything else in a playlist is dropped.
    static let playableSchemes: Set<String> = ["http", "https", "rtsp", "rtsps", "rtmp", "rtmps", "rtmpt", "udp", "rtp", "srt", "mms", "mmsh"]

    /// Stream URLs from a playlist: only schemes a player can actually open.
    static func isPlayableScheme(_ url: URL) -> Bool {
        playableSchemes.contains(url.scheme?.lowercased() ?? "")
    }
}
