import SwiftUI

/// Shown once, on first launch: automatic problem reports are on, what they contain, and where to turn them off.
struct LoggingNotice: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !DiagnosticsUploader.shared.noticeShown else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)           // after the first screen has appeared
                if !Task.isCancelled { show = true }
            }
            .alert("Automatic problem reports", isPresented: $show) {
                Button("OK") { DiagnosticsUploader.shared.noticeShown = true }
                Button("Turn Off") { DiagnosticsUploader.shared.isEnabled = false; DiagnosticsUploader.shared.noticeShown = true }
            } message: {
                Text("To help fix playback problems, StreamSetu sends a playback log to the developer when a stream fails. Server names are hidden, and logins, playlist names, titles and stream addresses are never sent. To turn this off, go to Settings → Send Feedback → Share playback logs automatically.")
            }
    }
}

extension View {
    func loggingNotice() -> some View { modifier(LoggingNotice()) }
}
