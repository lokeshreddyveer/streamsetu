import Testing
import Foundation

/// Status lines, toasts, banners and error text that reach the person must be built with Localized, or they stay English under Hindi and Telugu
/// (the bar status line and several Music toasts did). The scan reads Features/Music and Services/Music for a bare string literal handed to a toast or
/// notice call, or assigned to a status, banner, notice, error or note property, and for hotkey and comment wording passed as labelled literals.
///
/// Count based like AlwaysOnAnimationGuardTests. `safe` holds literals that are not user text (none yet); `pending` holds real offenders still to be
/// localised: fixing one means lowering or removing its entry, and a lower count than listed fails too.
struct UnlocalizedStatusTextGuardTests {
    static let safe: [String: (Int, String)] = [:]

    static let pendingFeatures: [String: (Int, String)] = [
        "Features/Music/Chrome/MusicCommentsView.swift": (3, "toast wording for a rejected or failed comment action is built from English literals; use Localized.string and add hi and te"),
        "Features/Music/Chrome/MusicOpenLinkDialog.swift": (1, "the 'not a recognised link' toast is a bare literal"),
        "Features/Music/Lyrics/Editor/MusicLyricsEditorModel.swift": (2, "the editor's banner and notice are bare literals"),
        "Features/Music/MusicDownloadsPage.swift": (1, "the download state label (Waiting, Downloading, Saved, Failed, Paused) is shown as plain text"),
        "Features/Music/MusicHotkeysSection.swift": (3, "hotkey registration and conflict notes are bare literals"),
        "Features/Music/MusicShortcuts.swift": (2, "hotkey recording errors are bare literals"),
    ]

    static let pendingServices: [String: (Int, String)] = [
        "Services/Music/Devices/MusicDeviceDiscovery.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Devices/MusicRemoteHost.swift": (2, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Karaoke/MusicKaraokeSeparator.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Karaoke/MusicKaraokeSource.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Local/LocalMediaFolders.swift": (2, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/MusicPluginUpdates.swift": (4, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Playback/MusicDownloads.swift": (2, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Plugins/MusicPluginAdapters.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Plugins/MusicPluginManager.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Providers/YouTubeMusic/Accounts/YouTubeMusicAccountManager.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Room/MusicRoomGuest.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Room/MusicRoomHost.swift": (2, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Room/MusicRoomSession.swift": (2, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Scrobble/ListenBrainzClient.swift": (1, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
        "Services/Music/Scrobble/MusicScrobbleConfig.swift": (8, "user-facing text built in the service as a bare literal; it must go through Localized.string with hi and te entries"),
    ]

    @Test func musicFeatureTextGoesThroughLocalized() {
        let found = GuardScans.unlocalizedStatusStrings(under: ["Features/Music"])
        let all = Self.safe.merging(Self.pendingFeatures) { a, b in (a.0 + b.0, a.1) }
        #expect(GuardScanner.overBudget(found, allowed: all).isEmpty, "User-facing text without Localized in Features/Music: \(GuardScanner.overBudget(found, allowed: all))")
        #expect(GuardScanner.staleEntries(found, allowed: all).isEmpty, "Lower or remove these entries: \(GuardScanner.staleEntries(found, allowed: all))")
    }

    @Test func musicServiceTextGoesThroughLocalized() {
        let found = GuardScans.unlocalizedStatusStrings(under: ["Services/Music"])
        let all = Self.safe.merging(Self.pendingServices) { a, b in (a.0 + b.0, a.1) }
        #expect(GuardScanner.overBudget(found, allowed: all).isEmpty, "User-facing text without Localized in Services/Music: \(GuardScanner.overBudget(found, allowed: all))")
        #expect(GuardScanner.staleEntries(found, allowed: all).isEmpty, "Lower or remove these entries: \(GuardScanner.staleEntries(found, allowed: all))")
    }

    @Test func theScanSeesTheShapesItIsMeantFor() throws {
        // The scan reads the app's own sources; this checks the pattern on text with the same shapes.
        let bad = ["MusicToasts.shared.error(\"That is not a recognised link.\")", "status = \"Too short to scrobble.\"", "showNotice(\"Playing next\")"]
        let good = ["MusicToasts.shared.error(Localized.string(\"That is not a recognised link.\"))", "status = Localized.string(\"Scrobbling is off.\")", "let n = 1"]
        let pattern = try NSRegularExpression(pattern: #"Toasts\.shared\.(show|error|success)\(\s*"|showNotice\(\s*"|\b(status|statusText|banner|notice|errorMessage|error|message|note|hint|summary|caption|detail|failure|problem|warning|toast)\s*=\s*(\(?[^"=\n]*\?\s*)?"[^"\n]*[A-Za-z]+ [^"\n]*""#)
        func hit(_ s: String) -> Bool { !s.contains("Localized") && pattern.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }
        for s in bad { #expect(hit(s), "\(s)") }
        for s in good { #expect(!hit(s), "\(s)") }
    }
}
