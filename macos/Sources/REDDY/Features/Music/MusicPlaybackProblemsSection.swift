import SwiftUI

/// The last playback failures with a plain reason each, so a song that did not start is never a mystery. The short list is kept in memory; the
/// detailed list (where it stopped, never an address) is kept on this device so a failure from last night can still be explained.
struct MusicPlaybackProblemsSection: View {
    private let log = MusicPlaybackLog.shared

    private var countText: String? {
        let n = max(log.entries.count, log.failures.count)
        return n == 0 ? nil : Localized.string("%d recent", n)
    }

    var body: some View {
        MusicSettingsGroup(title: "Playback problems", count: countText,
                           footer: "Kept on this device only. Web addresses are never stored, only the kind of host and a short code. Clear removes everything here.") {
            if log.entries.isEmpty && log.failures.isEmpty {
                MusicNote(text: "No problems so far. If a song does not start, the reason shows up here.")
            } else {
                ForEach(log.entries) { e in
                    MusicSettingsRow(title: e.track, detail: "\(e.provider): \(e.reason)") {
                        Text(e.at, style: .time).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                }
                if !log.failures.isEmpty {
                    MusicNote(text: "Where each failure stopped, newest first.")
                    ForEach(log.failures.prefix(10)) { f in
                        MusicSettingsRow(title: f.track, detail: Localized.string("Stopped at %1$@: %2$@", Localized.string(f.stage.rawValue), f.reason)) {
                            Text(f.at, style: .time).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                        }
                    }
                }
                MusicSettingsActions {
                    Button("Copy diagnostics") { Self.copy(log.diagnosticsText()) }
                        .accessibilityLabel(Text("Copy playback diagnostics")).atlas("control.music.musicCopyPlaybackDiagnostics")
                    Button("Clear") { log.clear() }.accessibilityLabel(Text("Clear playback problems")).atlas("control.music.musicClearPlaybackProblems")
                }
            }
        }
    }

    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        MusicToasts.shared.show(Localized.string("Copied"), kind: .info)
    }
}
