import Foundation

enum AppConfiguration {
    static let name = "StreamSetu"
    static let bundleID = "app.streamsetu.mac"
    /// The identifier the Mac app had before it was renamed. Its saved preferences are copied over once.
    static let legacyBundleID = "app.reddy.iptv"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static let minimumGuideRefresh: TimeInterval = 6 * 3600
}
