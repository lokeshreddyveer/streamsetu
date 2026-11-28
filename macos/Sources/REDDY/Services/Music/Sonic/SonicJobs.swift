import Foundation

/// The stored profiles: one small file, loaded when first asked for, written after each batch. A profile is replaced when the file changes or the analysis improves.
actor SonicStore {
    static let shared = SonicStore()
    private var records: [String: SonicRecord]?
    private let url: URL?
    private var unsaved = 0

    init(url: URL? = MusicStorage.subfolder("Sonic").appendingPathComponent("profiles.json")) { self.url = url }

    private func load() -> [String: SonicRecord] {
        if let records { return records }
        let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? MusicJSONCoding.makeDecoder().decode([String: SonicRecord].self, from: $0) } ?? [:]
        records = loaded
        return loaded
    }

    func profile(for key: String) -> SonicProfile? { load()[key]?.profile }
    func all() -> [SonicRecord] { Array(load().values) }
    func count() -> Int { load().count }

    /// True when the stored profile is current for this file.
    func isCurrent(key: String, stamp: Double) -> Bool {
        guard let r = load()[key] else { return false }
        return r.profile.version == SonicProfile.currentVersion && abs(r.stamp - stamp) < 1
    }

    func set(_ profile: SonicProfile, key: String, stamp: Double) {
        var r = load(); r[key] = SonicRecord(key: key, stamp: stamp, profile: profile); records = r
        unsaved += 1
        if unsaved >= 10 { flush() }
    }

    func flush() {
        unsaved = 0
        guard let url, let r = records, let d = try? MusicJSONCoding.makeEncoder().encode(r) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// Forgets every stored profile (the person's reset).
    func clear() { records = [:]; if let url { try? FileManager.default.removeItem(at: url) } }
}

/// The optional background analysis of the person's own songs. Off until they turn it on in Settings. It works through one song at a time at background priority,
/// and waits while music is playing, while Low Power Mode is on, or while the Mac is hot.
actor SonicJobs {
    static let shared = SonicJobs()
    static let enabledKey = "music.sonic.enabled"
    static var isEnabled: Bool { get { UserDefaults.standard.bool(forKey: enabledKey) } set { UserDefaults.standard.set(newValue, forKey: enabledKey) } }

    struct Status: Equatable, Sendable { var running = false; var done = 0; var total = 0; var waiting = false }
    private(set) var status = Status()
    private var task: Task<Void, Never>?

    func currentStatus() -> Status { status }

    /// Starts the job when analysis is switched on and none is running.
    func resumeIfEnabled(isPlaying: @escaping @Sendable () async -> Bool) {
        guard Self.isEnabled, task == nil, !MusicListeningModes.profile.pausesBackgroundWork else { return }
        task = Task.detached(priority: .background) { [weak self] in await self?.work(isPlaying: isPlaying) }
    }

    func stop() { task?.cancel(); task = nil; status.running = false }

    private static func shouldPause() -> Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical
    }

    private func finish() { task = nil; status.running = false; status.waiting = false }

    private func set(_ s: (inout Status) -> Void) { s(&status) }

    private func work(isPlaying: @Sendable () async -> Bool) async {
        status = Status(running: true, done: 0, total: 0, waiting: false)
        #if os(macOS)
        let entries = await LocalLibraryStore.shared.currentIndex().entries
        var pending: [LocalEntry] = []
        for e in entries where !(await SonicStore.shared.isCurrent(key: e.id, stamp: e.modified.timeIntervalSince1970)) { pending.append(e) }
        set { $0.total = pending.count }
        for e in pending {
            if Task.isCancelled || !Self.isEnabled { break }
            // Never competes with playback, battery saving or heat.
            while !Task.isCancelled, Self.isEnabled, await isPlaying() || Self.shouldPause() {
                set { $0.waiting = true }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            set { $0.waiting = false }
            if Task.isCancelled || !Self.isEnabled { break }
            do {
                let p = try await SonicAnalyzer.analyse(URL(fileURLWithPath: e.path))
                await SonicStore.shared.set(p, key: e.id, stamp: e.modified.timeIntervalSince1970)
            } catch is CancellationError { break } catch { /* unreadable or too short: skipped, the next scan retries */ }
            set { $0.done += 1 }
            await Task.yield()
        }
        await SonicStore.shared.flush()
        #endif
        finish()
    }
}
