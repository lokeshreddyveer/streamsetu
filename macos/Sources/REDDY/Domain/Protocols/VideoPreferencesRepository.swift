import Foundation

protocol VideoPreferencesRepository: Sendable {
    func globalLayout() -> VideoLayoutSettings
    func setGlobalLayout(_ l: VideoLayoutSettings)
    /// nil when the item has no override of its own.
    func layout(for itemID: String) -> VideoLayoutSettings?
    func setLayout(_ l: VideoLayoutSettings, for itemID: String)
    func clearLayout(for itemID: String)
}
