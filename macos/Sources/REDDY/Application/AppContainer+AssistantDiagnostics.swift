import Foundation

/// Gathers the evidence the assistant's diagnoses read. Nothing here returns an address, a login or a token: only counts, states, names the person gave their playlists, and plain-word statuses.
extension AppContainer {
    @MainActor func playbackEvidence() -> PlaybackEvidence {
        let p = playback, m = p.metrics, s = settings
        var e = PlaybackEvidence()
        e.playing = p.current != nil && p.state.isActive && { if case .failed = p.state { return false }; return true }()
        e.live = p.isLive
        e.state = "\(p.state)"
        if case .failed(let f) = p.state { e.failure = f; e.failureIsRecent = true }
        else if let f = p.lastError, let at = p.lastErrorAt, Date().timeIntervalSince(at) < 120, p.current != nil, p.state != .playing { e.failure = f; e.failureIsRecent = true }
        e.engine = p.activeEngine
        e.container = m.container
        e.enginePreference = s.enginePreference
        e.availableEngines = p.availableEngines
        e.stalls = m.stallCount; e.stallSeconds = m.totalStallSeconds; e.bufferedAhead = m.bufferedAheadSeconds
        e.droppedFrames = m.droppedFrames
        e.observedMbps = m.observedBitrate / 1_000_000; e.streamMbps = m.indicatedBitrate / 1_000_000
        e.width = m.width; e.height = m.height
        e.online = connectivity.online
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        e.timeline = p.timeline.suffix(8).map { "\($0.text) \(f.string(from: $0.at))" }
        e.hardwareDecoding = s.hardwareDecoding.rawValue
        e.buffering = s.bufferingMode.title
        return e
    }

    /// The playlists the person has, optionally narrowed by a name they typed.
    func assistantSources(matching name: String) -> [PlaylistSource] {
        let all = (try? catalog.sources()) ?? []
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return all }
        let hit = all.filter { $0.name.lowercased().contains(n) || $0.type.rawValue.contains(n) }
        return hit.isEmpty ? all : hit
    }

    func guideEvidence(for s: PlaylistSource) -> AssistantDiagnostics.GuideEvidence {
        let cov = try? epgRepo.guideCoverage(sourceID: s.id)
        var g = AssistantDiagnostics.GuideEvidence()
        g.source = s.name; g.sourceKind = s.type.rawValue
        g.hasGuideAddress = !(s.epgURL ?? "").isEmpty || s.type == .xtream     // Xtream playlists carry their own guide address
        g.channels = cov?.channels ?? 0; g.programmes = cov?.programs ?? 0; g.mapped = cov?.mapped ?? 0; g.lastUpdate = cov?.lastUpdate
        g.refreshSetting = settings.guideRefresh.rawValue
        g.shiftMinutes = settings.guideShiftMinutes(for: s.id)
        return g
    }

    /// A playlist's health: what is stored, how it last refreshed, and (when asked) whether its server answers. The server check is an ordinary request to the playlist's public address with no login.
    func sourceEvidence(for s: PlaylistSource, probe: Bool) async -> AssistantDiagnostics.SourceEvidence {
        var e = AssistantDiagnostics.SourceEvidence()
        e.name = s.name; e.kind = s.type.rawValue.replacingOccurrences(of: "_", with: " "); e.enabled = s.enabled; e.lastSync = s.lastSync; e.syncStatus = s.syncStatus
        let counts = (try? db.read { d in (try d.scalarInt("SELECT COUNT(*) FROM channels WHERE source_id=?", [s.id]), try d.scalarInt("SELECT COUNT(*) FROM movies WHERE source_id=?", [s.id]), try d.scalarInt("SELECT COUNT(*) FROM series WHERE source_id=?", [s.id])) }) ?? (0, 0, 0)
        e.channels = counts.0; e.movies = counts.1; e.series = counts.2
        e.guideProgrammes = (try? epgRepo.guideCoverage(sourceID: s.id))?.programs ?? 0
        e.warning = await MainActor.run { accounts.warnings().first { $0.sourceName == s.name }?.text }
        if probe, s.enabled, let url = URL(string: s.baseURL), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            e.probe = await Self.probeServer(url)
        }
        return e
    }

    static func probeServer(_ url: URL) async -> AssistantDiagnostics.SourceEvidence.Probe {
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.httpMethod = "GET"; r.setValue("bytes=0-0", forHTTPHeaderField: "Range"); r.setValue("StreamSetu", forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 8; cfg.timeoutIntervalForResource = 10
        do {
            let (_, resp) = try await URLSession(configuration: cfg).data(for: r)
            return .reachable((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { return .failed(PlaybackError.classify(error).kind) }
    }
}
