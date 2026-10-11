import Foundation

struct NetworkConfiguration: Sendable {
    var userAgent = "StreamSetu/1.0 (macOS)"
    var requestTimeout: TimeInterval = 60
    var maxPlaylistBytes: Int64 = 200 * 1024 * 1024
    var maxJSONBytes: Int64 = 150 * 1024 * 1024
    var maxEPGBytes: Int64 = 500 * 1024 * 1024
    var maxImageBytes: Int64 = 12 * 1024 * 1024
    static let `default` = NetworkConfiguration()
}
