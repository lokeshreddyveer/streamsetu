import SwiftUI

/// "Download" on a movie or episode, which turns into its progress, and then into a menu to remove the saved copy.
/// A ring that fills as a download proceeds, as Netflix shows it, with a small stop square inside while it runs.
struct DownloadRing: View {
    let fraction: Double
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.04, min(1, fraction))).stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: fraction)
            RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}

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
                } label: { ringLabel(r?.fraction ?? 0) }
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

    @ViewBuilder private func ringLabel(_ fraction: Double) -> some View {
        if compact { DownloadRing(fraction: fraction).accessibilityLabel("Downloading, \(Int(fraction * 100)) percent") }
        else { HStack(spacing: 6) { DownloadRing(fraction: fraction); Text("\(Int(fraction * 100))%").monospacedDigit() } }
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
                case .downloading:
                    ProgressView(value: r.fraction)
                    Text("\(Int(r.fraction * 100))%  ·  \(DownloadNaming.megabytes(r.bytesDone)) of \(DownloadNaming.megabytes(r.bytesTotal))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                case .done: Text(DownloadNaming.megabytes(r.bytesTotal)).font(.caption).foregroundStyle(.secondary)
                case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .paused: Text(r.error ?? "Paused").font(.caption).foregroundStyle(.secondary)
                case .failed: Text(r.error ?? "Failed").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch r.state {
            case .done: Button { container?.playSaved(r) } label: { Image(systemName: "play.fill") }.accessibilityLabel("Play")
            case .downloading: Button { d.pause(r.itemID) } label: { ZStack { DownloadRing(fraction: r.fraction, size: 24); Image(systemName: "pause.fill").font(.system(size: 8)) } }.accessibilityLabel("Pause")
            case .paused, .failed: Button { d.resume(r.itemID) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Resume")
            case .queued: EmptyView()
            }
            Button(role: .destructive) { d.remove(r.itemID) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove")
        }
        .buttonStyle(.borderless)
    }
}

#if os(macOS)
/// Recordings set up in the guide: what is waiting, what is recording now and how earlier ones ended.
struct ScheduledRecordingsList: View {
    @Environment(\.container) private var container
    var body: some View {
        if let service = container?.scheduledRecordings, !service.items.isEmpty {
            ForEach(service.items) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.title).lineLimit(1)
                        Text("\(r.channelName)  ·  \(r.start.formatted(date: .abbreviated, time: .shortened))  ·  " + status(r)).font(.caption).foregroundStyle(r.state == .failed || r.state == .missed ? Color.orange : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(role: .destructive) { service.remove(r.id) } label: { Image(systemName: r.state == .scheduled || r.state == .recording ? "xmark" : "trash") }.accessibilityLabel(r.state == .scheduled ? "Cancel" : "Remove")
                }.buttonStyle(.borderless)
            }
            Text("A scheduled recording opens its own connection to your provider, and the app has to be open at that time. The Mac stays awake while it records.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func status(_ r: ScheduledRecording) -> String {
        switch r.state {
        case .scheduled: return "Waiting"
        case .recording: return "Recording now"
        case .done: return "Recorded"
        case .failed: return r.detail ?? "Did not finish"
        case .missed: return r.detail ?? "Missed"
        }
    }
}

/// Everything recorded from live channels: play it, reveal it, remove it, and how much room it takes.
struct RecordingsList: View {
    @Environment(\.container) private var container
    @State private var items: [Recordings.Item] = []

    var body: some View {
        Group {
            if items.isEmpty {
                Text("Nothing is recorded yet. While a live channel plays with the MPV player, press the red dot in its controls.").foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(1)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened) + "  ·  " + DownloadNaming.megabytes(item.bytes)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { container?.playback.play(file: item.url, title: item.title + " (recorded)") } label: { Image(systemName: "play.fill") }.accessibilityLabel("Play")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }.accessibilityLabel("Show in Finder")
                        Button(role: .destructive) { try? FileManager.default.removeItem(at: item.url); items = Recordings.all() } label: { Image(systemName: "trash") }.accessibilityLabel("Remove")
                    }.buttonStyle(.borderless)
                }
                LabeledContent("Space used", value: DownloadNaming.megabytes(items.reduce(0) { $0 + $1.bytes }))
            }
        }
        .task { while !Task.isCancelled { items = Recordings.all(); try? await Task.sleep(nanoseconds: 3_000_000_000) } }
    }
}
#endif
