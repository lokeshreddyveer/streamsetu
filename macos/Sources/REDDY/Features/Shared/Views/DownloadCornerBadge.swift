import SwiftUI

/// On a poster: a small round badge for a title that is saved or being saved, with a ring that fills as it downloads.
struct DownloadCornerBadge: View {
    let titleID: String
    @Environment(\.container) private var container

    var body: some View {
        if let status = container?.downloads.status(forTitle: titleID) {
            ZStack {
                Circle().fill(.black.opacity(0.65))
                if status.state == .downloading {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.04, status.fraction)).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol(status.state)).font(.system(size: 9, weight: .bold)).foregroundStyle(status.state == .done ? Color(red: 0.4, green: 0.85, blue: 0.55) : .white)
            }
            .frame(width: 20, height: 20).shadow(color: .black.opacity(0.4), radius: 2)
            .accessibilityLabel(label(status))
        }
    }

    private func symbol(_ state: DownloadRecord.State) -> String {
        switch state {
        case .queued: "clock"
        case .downloading: "arrow.down"
        case .paused: "pause.fill"
        case .failed: "exclamationmark"
        case .done: "arrow.down.to.line"
        }
    }

    private func label(_ status: (state: DownloadRecord.State, fraction: Double)) -> String {
        switch status.state {
        case .queued: "Waiting to download"
        case .downloading: "Downloading, \(Int(status.fraction * 100)) percent"
        case .paused: "Download paused"
        case .failed: "Download failed"
        case .done: "Downloaded"
        }
    }
}
