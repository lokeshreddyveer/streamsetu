import SwiftUI
import Observation
import AppKit

@MainActor @Observable
final class AdvancedSettingsViewModel {
    var report = ""
    var reportMessage: SettingsMessage?
    var resetMessage: SettingsMessage?
    var about = AboutInfo()
    var summary = DataSummary()
    var showLicenses = false

    func loadAbout(_ c: AppContainer) async {
        var a = AboutInfo()
        a.schemaVersion = (try? c.db.read { try $0.scalarInt("PRAGMA user_version") }) ?? 0
        a.bundledLibraries = AboutInfo.bundledLibraryNames()
        let v = await Task.detached { EngineInfoService.libraryVersions() }.value
        a.mpvVersion = v.mpv; a.ffmpegVersion = v.ffmpeg
        about = a
        summary = await Task.detached { [reset = c.dataReset] in reset.summary() }.value
    }

    func generate(_ c: AppContainer) async {
        let engines = EngineInfoService.reports(c.playback).map { "\($0.title): \($0.available ? "available" : "unavailable")\($0.problem.map { " (\($0))" } ?? "")" }
        let playback = c.playback.diagnosticsSummary
        let d = c.diagnostics
        report = await Task.detached { d.report(playback: playback, engines: engines) }.value
        reportMessage = .init(text: "Report generated. Logins, tokens and stream addresses are removed.")
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        reportMessage = .init(text: "Report copied.")
    }

    func save() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        if WindowManager.saveFile(name: "StreamSetu-diagnostics-\(f.string(from: Date())).txt", data: Data(report.utf8)) { reportMessage = .init(text: "Report saved.") }
    }

    /// REDDY writes to the unified system log (subsystem app.streamsetu.mac), which Console shows.
    func revealLogs() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") { NSWorkspace.shared.open(url) }
        reportMessage = .init(text: "Console opened. Search for “app.streamsetu.mac” to see StreamSetu's log entries.", kind: .info)
    }

    // MARK: resets

    func resetAppearance(_ c: AppContainer) { c.settings.resetAppearance(); resetMessage = .init(text: "Appearance reset.") }
    func resetPlayback(_ c: AppContainer) { c.settings.resetPlayback(); c.playback.setAudioProcessing(.off); resetMessage = .init(text: "Playback preferences reset.") }
    func resetAllPreferences(_ c: AppContainer) { c.settings.resetAll(); c.playback.setAudioProcessing(.off); resetMessage = .init(text: "All preferences reset. Playlists, favorites and history were not changed.") }

    func clearHistory(_ c: AppContainer, state: AppState) {
        do { try c.dataReset.clearViewingHistory(); state.catalogVersion += 1; resetMessage = .init(text: "Viewing history and resume points cleared.") }
        catch { resetMessage = .init(text: "Couldn't clear history: \(error.localizedDescription)", kind: .failure) }
    }

    func clearSearchHistory(_ c: AppContainer) { c.search.clearHistory(); resetMessage = .init(text: "Search history cleared.") }

    func clearArtwork(_ c: AppContainer) async { await c.artwork.clear(); resetMessage = .init(text: "Artwork cache cleared.") }

    func removeEverything(_ c: AppContainer, state: AppState) async {
        c.playback.stop()
        let reset = c.dataReset
        do {
            try await Task.detached { try reset.removeEverything() }.value
            await c.artwork.clear()
            state.reload(); state.catalogVersion += 1
            resetMessage = .init(text: "All playlists and library data were removed from this Mac.")
        } catch { resetMessage = .init(text: "Couldn't remove everything: \(error.localizedDescription)", kind: .failure) }
        summary = await Task.detached { reset.summary() }.value
    }
}
