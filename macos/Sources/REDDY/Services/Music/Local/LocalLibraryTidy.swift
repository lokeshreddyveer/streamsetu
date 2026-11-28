import Foundation
#if os(macOS)
import CoreServices
#endif

// Keeping the local library tidy: the same song stored twice, songs in playlists whose file went away, and noticing new or removed files by itself.
// The rules are plain functions; nothing here deletes a file from the disk.

enum LocalLibraryTidy {
    struct DuplicateGroup: Equatable, Sendable, Identifiable {
        var entries: [LocalEntry]
        var id: String { entries.first?.id ?? "" }
        /// The copy to keep: lossless first, then the larger bitrate guess by extension, then the longer file name path that is not a "copy".
        var keeper: LocalEntry { entries.max { rank($0) < rank($1) } ?? entries[0] }
        var extras: [LocalEntry] { entries.filter { $0.id != keeper.id } }
    }

    static let lengthToleranceMs: Int64 = 3_000

    private static let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "aif"]
    private static let rankOfExt: [String: Int] = ["flac": 5, "alac": 5, "wav": 5, "aiff": 5, "aif": 5, "m4a": 3, "aac": 3, "ogg": 3, "opus": 3, "mp3": 2]

    static func rank(_ e: LocalEntry) -> Int {
        let base = (rankOfExt[e.ext.lowercased()] ?? 1) * 10
        let copyPenalty = e.path.lowercased().contains("copy") ? 1 : 0
        return base - copyPenalty
    }

    /// Songs with the same title and artist and about the same length. A different version (remix, live) has its own title, so it never counts.
    static func duplicates(_ entries: [LocalEntry]) -> [DuplicateGroup] {
        var byKey: [String: [LocalEntry]] = [:]
        for e in entries {
            let title = MusicText.normalize(e.title)
            guard !title.isEmpty else { continue }
            byKey[title + "|" + MusicText.normalize(LocalLibraryIndex.primaryArtist(of: e)), default: []].append(e)
        }
        var out: [DuplicateGroup] = []
        for (_, list) in byKey where list.count > 1 {
            var clusters: [[LocalEntry]] = []
            for e in list.sorted(by: { $0.path < $1.path }) {
                if let i = clusters.firstIndex(where: { c in c.contains { sameLength($0, e) } }) { clusters[i].append(e) } else { clusters.append([e]) }
            }
            out += clusters.filter { $0.count > 1 }.map { DuplicateGroup(entries: $0) }
        }
        return out.sorted { $0.keeper.title.localizedCaseInsensitiveCompare($1.keeper.title) == .orderedAscending }
    }

    private static func sameLength(_ a: LocalEntry, _ b: LocalEntry) -> Bool {
        a.durationMs <= 0 || b.durationMs <= 0 || abs(a.durationMs - b.durationMs) <= lengthToleranceMs
    }

    /// A song that lives on this device whose file is not there any more.
    struct MissingSong: Equatable, Sendable, Identifiable {
        var track: MusicTrack
        var path: String
        var playlistIDs: [UUID]
        var id: String { track.uid }
    }

    static func filePath(of t: MusicTrack) -> String? {
        guard t.providerID == MusicStatsRules.localProviderID, let s = t.directStreams?.first?.url, let u = URL(string: s), u.isFileURL else { return nil }
        return u.path
    }

    /// Local songs held by playlists whose file no longer exists, each with the playlists that hold it.
    static func missing(in playlists: [LocalPlaylist], exists: (String) -> Bool) -> [MissingSong] {
        var by: [String: MissingSong] = [:]
        for p in playlists {
            for t in p.tracks {
                guard let path = filePath(of: t), !exists(path) else { continue }
                var m = by[t.uid] ?? MissingSong(track: t, path: path, playlistIDs: [])
                if !m.playlistIDs.contains(p.id) { m.playlistIDs.append(p.id) }
                by[t.uid] = m
            }
        }
        return by.values.sorted { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending }
    }

    /// The playlist's songs with `old` replaced by `new` (where it stands), and a repeat of `new` already in the list dropped.
    static func replacing(_ old: MusicTrack, with new: MusicTrack, in tracks: [MusicTrack]) -> [MusicTrack] {
        var out: [MusicTrack] = []
        var seen = Set<String>()
        for t in tracks {
            let t2 = t.uid == old.uid ? new : t
            if seen.insert(t2.uid).inserted { out.append(t2) }
        }
        return out
    }
}

#if os(macOS)
/// Watches the chosen music folders and calls back a few seconds after files are added, moved or removed, so the library follows the disk by itself.
final class LocalFolderWatcher: @unchecked Sendable {
    static let delay: TimeInterval = 4
    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable () -> Void)?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "StreamSetu.Music.LocalWatch", qos: .utility)

    func start(paths: [String], onChange: @escaping @Sendable () -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LocalFolderWatcher>.fromOpaque(info).takeUnretainedValue().fired()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        pending?.cancel(); pending = nil
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private func fired() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    deinit { stop() }
}
#endif
