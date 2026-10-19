import SwiftUI

/// "Download" on a movie or episode, which turns into its progress, and then into a menu to remove the saved copy.
struct DownloadButton: View {
    let itemID: String
    var compact = false
    let start: (DownloadService) -> Void
    @Environment(\.container) private var container

    var body: some View {
        if let d = container?.downloads {
            let r = d.record(for: itemID)
            switch r?.state {
            case nil:
                Button { start(d) } label: { label("Download", "arrow.down.circle") }
            case .failed?:
                Menu {
                    if let e = r?.error { Text(e) }
                    Button("Try Again") { start(d) }
                    Button("Remove", role: .destructive) { d.remove(itemID) }
                } label: { label("Download Failed", "exclamationmark.arrow.circlepath") }
            case .queued?:
                Menu { Button("Cancel Download", role: .destructive) { d.remove(itemID) } } label: { label("Waiting", "clock") }
            case .downloading?:
                Menu {
                    Button("Pause") { d.pause(itemID) }
                    Button("Cancel Download", role: .destructive) { d.remove(itemID) }
                } label: { label("\(Int((r?.fraction ?? 0) * 100)) %", "arrow.down.circle.fill") }
            case .paused?:
                Menu {
                    Button("Resume") { d.resume(itemID) }
                    Button("Cancel Download", role: .destructive) { d.remove(itemID) }
                } label: { label("Paused", "pause.circle") }
            case .done?:
                Menu { Button("Remove Download", role: .destructive) { d.remove(itemID) } } label: { label("Downloaded", "checkmark.circle.fill") }
            }
        }
    }

    @ViewBuilder private func label(_ text: String, _ symbol: String) -> some View {
        if compact { Image(systemName: symbol).accessibilityLabel(text) } else { Label(text, systemImage: symbol) }
    }
}

/// Everything saved or saving: progress, pause and resume, play, remove, and how much space it takes.
struct DownloadsList: View {
    @Environment(\.container) private var container

    var body: some View {
        if let d = container?.downloads {
            Group {
                if d.records.isEmpty {
                    Text("Nothing is saved yet. Choose Download on a movie or an episode.").foregroundStyle(.secondary)
                } else {
                    ForEach(d.records) { r in row(r, d) }
                    LabeledContent("Space used", value: DownloadNaming.megabytes(d.totalBytes))
                }
            }
        }
    }

    private func row(_ r: DownloadRecord, _ d: DownloadService) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).lineLimit(1)
                if let s = r.subtitle, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                switch r.state {
                case .downloading: ProgressView(value: r.fraction)
                case .done: Text(DownloadNaming.megabytes(r.bytesTotal)).font(.caption).foregroundStyle(.secondary)
                case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .paused: Text(r.error ?? "Paused").font(.caption).foregroundStyle(.secondary)
                case .failed: Text(r.error ?? "Failed").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch r.state {
            case .done: Button { container?.playSaved(r) } label: { Image(systemName: "play.fill") }.accessibilityLabel("Play")
            case .downloading: Button { d.pause(r.itemID) } label: { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
            case .paused, .failed: Button { d.resume(r.itemID) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Resume")
            case .queued: EmptyView()
            }
            Button(role: .destructive) { d.remove(r.itemID) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove")
        }
        .buttonStyle(.borderless)
    }
}
