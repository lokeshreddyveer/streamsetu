import Foundation
import Observation
import AVFoundation

/// The list of conversions: watch them, cancel one or all. They run one at a time so the Mac stays responsive.
@MainActor @Observable
final class MusicConversionQueue {
    static let shared = MusicConversionQueue()

    struct Job: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, failed(String), cancelled }
        var id = UUID()
        var title: String
        var inputs: [URL]
        var output: URL
        var preset: MusicConversionPreset
        var range: ClosedRange<Double>? = nil
        var entry: LocalEntry? = nil
        var state: State = .waiting
        var progress = 0.0
        var seconds = 0.0
    }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var cancelFlags = CancelFlags()

    var isBusy: Bool { jobs.contains { $0.state == .waiting || $0.state == .running } }
    var finishedCount: Int { jobs.filter { $0.state == .done }.count }

    func add(_ job: Job) { jobs.append(job); start() }
    func add(_ list: [Job]) { jobs += list; start() }

    func cancel(_ id: UUID) {
        cancelFlags.cancel(id)
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting { jobs[i].state = .cancelled }
    }
    func cancelAll() { for j in jobs where j.state == .waiting || j.state == .running { cancel(j.id) } }
    func clearFinished() {
        jobs.removeAll { j in
            switch j.state { case .waiting, .running: false; default: true }
        }
    }

    private func start() {
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            while let self, let i = self.jobs.firstIndex(where: { $0.state == .waiting }) {
                await self.run(index: i)
            }
            self?.runner = nil
        }
    }

    private func run(index i: Int) async {
        let job = jobs[i]
        jobs[i].state = .running
        let id = job.id, flags = cancelFlags
        do {
            let secs = try await Task.detached(priority: .utility) { [weak self] in
                try await MusicConverter.convert(inputs: job.inputs, to: job.output, preset: job.preset, range: job.range,
                                                 progress: { p in Task { @MainActor in self?.setProgress(id, p) } }, isCancelled: { flags.isCancelled(id) })
            }.value
            if let bad = MusicConverter.verify(job.output, expectedSeconds: secs) { try? FileManager.default.removeItem(at: job.output); throw bad }
            await MusicConverter.carryOver(job.entry, to: job.output, format: job.preset.format)
            update(id) { $0.state = .done; $0.progress = 1; $0.seconds = secs }
        } catch let e as MusicConvertError {
            update(id) { $0.state = e == .cancelled ? .cancelled : .failed(e.message) }
        } catch { update(id) { $0.state = .failed(MusicConvertError.cannotWrite.message) } }
    }

    private func setProgress(_ id: UUID, _ p: Double) { update(id) { $0.progress = p } }
    private func update(_ id: UUID, _ change: (inout Job) -> Void) { if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) } }
}

private final class CancelFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UUID>()
    func cancel(_ id: UUID) { lock.lock(); ids.insert(id); lock.unlock() }
    func isCancelled(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

// MARK: splitting a CUE image, artwork, disc import

enum MusicConvertTools {
    /// One job per chapter of the CUE sheet next to `audio`, each written as "NN - Title".
    static func splitJobs(audio: URL, chapters: [MusicChapter], duration: Double, preset: MusicConversionPreset, folder: URL, album: String?, artist: String?) -> [MusicConversionQueue.Job] {
        chapters.enumerated().map { i, c in
            let end = i + 1 < chapters.count ? chapters[i + 1].start : duration
            let name = String(format: "%02d - ", c.number) + c.title
            return MusicConversionQueue.Job(title: c.title, inputs: [audio], output: MusicConverter.output(for: audio, in: folder, format: preset.format, name: name), preset: preset, range: c.start...max(c.start + 0.5, end),
                                            entry: LocalEntry(id: "", folderID: "", path: audio.path, title: c.title, artist: c.performer ?? artist ?? "", album: album ?? "", trackNumber: c.number, durationMs: 0, modified: Date(), artworkFile: nil, ext: audio.pathExtension))
        }
    }

    /// The tracks of an audio CD that macOS has mounted (they appear as AIFF files on the disc's volume). Only the person's own disc, in their own drive.
    static func discTracks() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for v in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeIsLocalKey], options: [.skipsHiddenFiles])) ?? [] {
            let files = ((try? fm.contentsOfDirectory(at: v, includingPropertiesForKeys: nil)) ?? []).filter { ["aiff", "aif"].contains($0.pathExtension.lowercased()) }
            let isDisc = files.contains { $0.lastPathComponent.range(of: #"^\d+ Audio Track"#, options: .regularExpression) != nil }
            if isDisc { out += files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
        }
        return out
    }

    /// Saves the cover picture a song carries (its cached copy) next to where the person chose.
    static func extractArtwork(of entry: LocalEntry, artworkDirectory: URL, to folder: URL) -> URL? {
        guard let f = entry.artworkFile else { return nil }
        let src = artworkDirectory.appendingPathComponent(f)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let base = MusicRenameTemplate.clean(entry.album.isEmpty ? entry.title : entry.album)
        var dest = folder.appendingPathComponent(base + "." + (src.pathExtension.isEmpty ? "jpg" : src.pathExtension))
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n)." + (src.pathExtension.isEmpty ? "jpg" : src.pathExtension)); n += 1 }
        do { try FileManager.default.copyItem(at: src, to: dest); return dest } catch { return nil }
    }

    /// Stores a picture in an AAC or Apple Lossless file by writing a new copy of the file with the cover in it, then replacing the original only when the copy is good.
    /// Respects the read-only collection: callers check `MusicCollectionSafety` first.
    static func embedArtwork(_ image: Data, into file: URL) async -> Bool {
        let asset = AVURLAsset(url: file)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".cover-" + UUID().uuidString + ".m4a")
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = image as NSData
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        let existing = (try? await asset.load(.metadata)) ?? []
        session.metadata = existing.filter { $0.identifier != .commonIdentifierArtwork && $0.identifier != .iTunesMetadataCoverArt } + [item]
        session.outputURL = tmp; session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { try? FileManager.default.removeItem(at: tmp); return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (try? FileManager.default.replaceItemAt(file, withItemAt: tmp)) != nil
    }
}
