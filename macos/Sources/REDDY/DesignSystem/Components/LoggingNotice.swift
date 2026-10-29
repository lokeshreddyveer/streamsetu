import SwiftUI

/// Asked once, on first launch: may StreamSetu send a playback log when a stream fails for good? The answer is no until the person says yes, and it can be changed in Settings → Send Feedback.
struct LoggingNotice: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !DiagnosticsUploader.shared.noticeShown else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)           // after the first screen has appeared
                if !Task.isCancelled { show = true }
            }
            .alert("Help fix playback problems?", isPresented: $show) {
                Button("Share Logs") { DiagnosticsUploader.shared.isEnabled = true; DiagnosticsUploader.shared.noticeShown = true }
                Button("Not Now", role: .cancel) { DiagnosticsUploader.shared.isEnabled = false; DiagnosticsUploader.shared.noticeShown = true }
            } message: {
                Text("When a stream fails for good, StreamSetu can send the recent playback log to the developer: which player was used, timings and error codes, your app and system version, your device model and a random report number made on this device. Server names are hidden, and logins, playlist names, titles and stream addresses are never sent. Nothing is sent unless you choose Share Logs. You can change this in Settings → Send Feedback.")
            }
    }
}

extension View {
    func loggingNotice() -> some View { modifier(LoggingNotice()) }
}
