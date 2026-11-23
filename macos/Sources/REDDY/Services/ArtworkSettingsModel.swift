import Foundation
import Observation

/// What Settings → Artwork and Details shows and does, for the Mac and iOS screens alike.
@MainActor @Observable final class ArtworkSettingsModel {
    var hasOwnKey = false
    var source: TMDBAccess.Source = .none
    var builtInRejected = false
    var enabled = true
    var allowCellular = false
    var trending = true
    var status = ArtworkMatchStatus()
    var message: String?
    var messageFailed = false
    var testing = false

    private let container: AppContainer
    private var observer: UUID?
    init(container: AppContainer) { self.container = container; refresh() }

    nonisolated static let optionalNote = "StreamSetu works without a key of your own. Adding your own free key is optional, and it is used instead of the built-in one."
    nonisolated static let switchNote = "Finds posters your playlist doesn't provide, automatically, on any network unless you turn mobile data off. Details, cast and backdrops load when you open a title. Only the title and year are sent. Anything your playlist already provides is left alone, and titles in locked or hidden folders are never sent."
    nonisolated static let sentNote = "Only the title and year are sent. Anything your playlist already provides is left alone, and titles in locked or hidden folders are never sent. Like any website, the services and image hosts can see your device's IP address."
    nonisolated static let brokenBuiltIn = "The built-in key is not working; add your own free key to keep artwork."

    var sourceLine: String {
        switch source {
        case .own: "Using your key"
        case .builtIn: "Using the built-in key"
        case .none: builtInRejected ? Self.brokenBuiltIn : "No key in use. Add your own free key to match artwork."
        }
    }
    var keyHint: String { hasOwnKey ? "Your key is saved on this device." : "Optional. Create a free account at themoviedb.org, then copy your API key (or read access token) from Settings → API." }
    var progressLine: String { status.line }
    var canMatch: Bool { source != .none }
    var isRunning: Bool { status.state == .running || status.state == .backingOff }

    func refresh() {
        let m = container.metadata, a = container.artworkMatcher
        hasOwnKey = m.hasOwnKey; source = m.keySource; builtInRejected = m.access.builtInRejected
        enabled = a.enabled; allowCellular = a.allowCellular; trending = container.smartMix.trendingEnabled
        status = a.status
        if observer == nil { observer = a.observe { [weak self] s in Task { @MainActor in self?.status = s; self?.source = self?.container.metadata.keySource ?? .none } } }
        Task.detached { [a] in let s = a.statusRefreshed(); await MainActor.run { self.status = s } }
    }
    func disappear() { if let o = observer { container.artworkMatcher.removeObserver(o); observer = nil } }

    func save(_ key: String) {
        do { try container.metadata.saveKey(key); afterKeyChange(); say("Key saved.") } catch { say("The key could not be saved.", failed: true) }
    }
    func remove() {
        do { try container.metadata.removeKey(); container.metadata.purgePeople(); afterKeyChange(); say("Your key was removed." + (source == .builtIn ? " The built-in key is used again." : "")) }
        catch { say("Could not remove the key.", failed: true) }
    }
    private func afterKeyChange() {
        container.smartMix.applyPolicy(); container.smartMix.refreshTrendingIfNeeded(); container.smartMix.invalidate(.prefsChange)
        refresh(); if canMatch { container.artworkMatcher.start() } else { container.artworkMatcher.stop() }
    }
    func test() {
        testing = true; say("Checking…")
        let m = container.metadata
        Task {
            do { try await m.verifyKey(); say(source == .builtIn ? "TMDB accepted the built-in key." : "TMDB accepted your key.") }
            catch { say((error as? MetadataMatchService.MatchError)?.settingsMessage ?? error.localizedDescription, failed: true) }
            testing = false; refresh()
        }
    }
    func matchNow() { container.artworkMatcher.matchNow(); message = nil }
    func setEnabled(_ on: Bool) { enabled = on; if !on { container.metadata.purgePeople() }; container.artworkMatcher.enabled = on; status = container.artworkMatcher.status }
    func setCellular(_ on: Bool) { allowCellular = on; container.artworkMatcher.allowCellular = on }
    func setTrending(_ on: Bool) { trending = on; container.smartMix.trendingEnabled = on }
    private func say(_ m: String, failed: Bool = false) { message = m; messageFailed = failed }
}

extension ArtworkAutoMatcher {
    /// The status with counts read now (off the main thread).
    func statusRefreshed() -> ArtworkMatchStatus { refreshCounts(); return status }
}
