import AVFoundation
import CoreImage
import CoreMedia

/// Apple's native engine. One long-lived AVPlayer is reused for every item, so switching channels swaps the
/// item underneath instead of rebuilding the player or its views. Raw MPEG-TS live streams go through the
/// local HLS bridge.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind = PlaybackEngineKind.avPlayer
    let player: AVPlayer = {
        let p = AVPlayer()
        p.automaticallyWaitsToMinimizeStalling = true
        p.allowsExternalPlayback = true          // AirPlay
        return p
    }()
    let capabilities = PlaybackCapabilities(containers: [.hls, .mp4, .mpegTS], pictureInPicture: true, airPlay: true, screenshot: true, qualitySelection: true)
    var bufferingMode: BufferingMode = .automatic
    var qualityPreference: VideoQualityPreference = .automatic
    private(set) var lastHTTPStatus: Int?
    private(set) var metrics = PlaybackMetrics()

    let stateUpdates: AsyncStream<PlaybackState>
    private let continuation: AsyncStream<PlaybackState>.Continuation
    private var machine = PlaybackStateMachine()
    var state: PlaybackState { machine.state }

    private var observer: AVPlayerObserver?
    private var bridge: TSBridge?
    private var traceTicks = 0
    private var request: PlaybackRequest?
    private var userPaused = false
    private var pendingStart: TimeInterval = 0
    private var buffering = BufferingMonitor()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var desiredRate: Float = 1
    private var subtitleStyle = SubtitleStyle()
    private var loadGeneration = 0
    private var qualities: [QualityOption] = []
    private(set) var selectedQualityID: String?

    init() {
        (stateUpdates, continuation) = AsyncStream.makeStream(of: PlaybackState.self, bufferingPolicy: .bufferingNewest(8))
    }

    // MARK: state

    private func send(_ e: PlaybackEvent) {
        let before = machine.state
        if machine.send(e), machine.state != before { continuation.yield(machine.state) }
    }

    var position: TimeInterval {
        let s = player.currentTime().seconds
        return s.isFinite ? max(0, s) : 0
    }

    var duration: TimeInterval? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    // MARK: loading

    func load(_ request: PlaybackRequest) async throws {
        teardown()
        loadGeneration += 1
        let generation = loadGeneration
        self.request = request
        lastHTTPStatus = nil
        userPaused = false
        send(.startResolving)
        send(.resolved)
        let container = StreamCapabilities.container(for: request.url, isLive: request.isLive)
        metrics = PlaybackMetrics(engine: .avPlayer, container: container, host: request.url.host ?? "")
        buffering.reset()

        var playURL = request.url
        if request.isLive, container == .mpegTS {
            let b = TSBridge(source: request.url, headers: request.headers)
            bridge = b
            do { playURL = try await b.start() }
            catch { let e = PlaybackError.classify(error); send(.failed(e)); throw e }
            guard generation == loadGeneration else { b.stop(); return }          // superseded by a newer channel
        }

        // Headers go to the provider's own address; the local bridge address needs none.
        let item: AVPlayerItem
        if !request.headers.isEmpty, playURL == request.url {
            item = AVPlayerItem(asset: AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": request.headers]))
        } else { item = AVPlayerItem(url: playURL) }
        item.preferredForwardBufferDuration = bufferingMode.forwardBufferSeconds
        item.preferredPeakBitRate = qualityPreference.peakBitRate
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        // Live HLS: sit further behind the live edge when a steadier picture was asked for. More headroom, more delay.
        if request.isLive, let behind = bufferingMode.liveEdgeOffsetSeconds {
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.configuredTimeOffsetFromLive = CMTime(seconds: behind, preferredTimescale: 600)
        }
        item.textStyleRules = styleRules()
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        videoOutput = out
        pendingStart = request.isLive ? 0 : request.startPosition
        observer = AVPlayerObserver(player: player, item: item) { [weak self] e in self?.handle(e, generation: generation) }
        player.replaceCurrentItem(with: item)
        try await play()
    }

    private func handle(_ e: AVPlayerObserver.Event, generation: Int) {
        guard generation == loadGeneration else { return }
        switch e {
        case .ready:
            Task { await onReadyToPlay() }
        case .failed(let err):
            fail(err)
        case .timeControl(let s):
            switch s {
            case .playing:
                buffering.playing()
                metrics.startupSeconds = metrics.startupSeconds ?? buffering.startupSeconds
                send(.ready)
            case .waitingToPlayAtSpecifiedRate:
                if state != .paused, state != .seeking { buffering.bufferingBegan(); send(.buffering) }
            case .paused:
                if userPaused { send(.pause) }
            @unknown default: break
            }
        case .stalled:
            buffering.bufferingBegan(); send(.buffering)
        case .reachedEnd:
            if request?.isLive == true { fail(PlaybackError(.network, detail: "The live stream ended.")) } else { send(.reachedEnd) }
        case .tick:
            updateMetrics()
        }
    }

    private func fail(_ error: Error) {
        if Trace.on, let item = player.currentItem {
            for ev in item.errorLog()?.events ?? [] { Trace.log("AVPlayer errorLog status=\(ev.errorStatusCode) domain=\(ev.errorDomain) comment=\(ev.errorComment ?? "-") uri=\(ev.uri.flatMap(URL.init(string:)).map(Trace.describe) ?? "-")") }
            Trace.log("AVPlayer item status=\(item.status.rawValue) bridge http=\(bridge?.httpStatus.map(String.init) ?? "-")")
        }
        let status = bridge?.httpStatus
        let e = bridge?.receivedNothing == true
            ? PlaybackError(.providerBusy)
            : PlaybackError.classify(error, httpStatus: (status != nil && status != 200) ? status : nil)
        lastHTTPStatus = bridge?.httpStatus
        Log.playback.error("AVPlayer failed: \(e.kind.rawValue) \(e.detail ?? "")")
        send(.failed(e))
    }

    private func onReadyToPlay() async {
        guard let item = player.currentItem else { return }
        if let why = bridge?.unsupportedVideo {
            // Apple's player would play sound with no picture. Say so, so the other player takes over.
            Trace.log("AVPlayer cannot show this channel: \(why)")
            fail(PlaybackError(.unsupportedFormat, detail: "Apple's player can't show this channel's video (\(why))."))
            return
        }
        let generation = loadGeneration
        await loadQualities(item)
        audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard generation == loadGeneration else { return }
        if pendingStart > 5 {
            let t = pendingStart; pendingStart = 0
            try? await seek(to: t)
        }
        if let tracks = try? await item.asset.load(.tracks) {
            for t in tracks {
                guard let desc = (try? await t.load(.formatDescriptions))?.first else { continue }
                let code = String(fourCC: CMFormatDescriptionGetMediaSubType(desc))
                if t.mediaType == .video { metrics.videoCodec = code; metrics.frameRate = Double((try? await t.load(.nominalFrameRate)) ?? 0) }
                if t.mediaType == .audio { metrics.audioCodec = code }
                if Trace.on {
                    let playable = (try? await t.load(.isPlayable)).map(String.init) ?? "?"
                    let natural = (try? await t.load(.naturalSize)).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                    Trace.log("AVPlayer track \(t.mediaType.rawValue) codec=\(code) playable=\(playable) size=\(natural)")
                }
            }
        }
        Trace.log("AVPlayer ready presentationSize=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) video=\(metrics.videoCodec ?? "-") audio=\(metrics.audioCodec ?? "-")")
    }

    private func updateMetrics() {
        guard let item = player.currentItem else { return }
        let size = item.presentationSize
        metrics.width = Int(size.width); metrics.height = Int(size.height)
        traceTicks += 1
        if Trace.on, traceTicks % 8 == 0 { Trace.log("AVPlayer tick pos=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(size.width))x\(Int(size.height)) rate=\(player.rate) stalls=\(buffering.stalls) bufferedAhead=\(String(format: "%.1f", metrics.bufferedAheadSeconds ?? 0))") }
        if let e = item.accessLog()?.events.last {
            metrics.observedBitrate = e.observedBitrate
            metrics.indicatedBitrate = e.indicatedBitrate
            metrics.droppedFrames = e.numberOfDroppedVideoFrames
        }
        metrics.stallCount = buffering.stalls
        metrics.totalStallSeconds = buffering.stalledSeconds
        if let r = item.loadedTimeRanges.first?.timeRangeValue {
            metrics.bufferedAheadSeconds = max(0, r.end.seconds - player.currentTime().seconds)
        }
    }

    // MARK: transport

    func play() async throws {
        userPaused = false
        player.defaultRate = desiredRate
        player.play()
        if state == .paused { send(.resume) }
    }

    func pause() {
        userPaused = true
        player.pause()
        send(.pause)
    }

    func stop() {
        loadGeneration += 1
        teardown()
        request = nil
        send(.stop)
    }

    func seek(to position: TimeInterval) async throws {
        guard player.currentItem != nil else { return }
        send(.seekBegan)
        let target = CMTime(seconds: max(0, position), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        send(.seekEnded)
        if userPaused { send(.pause) } else if player.timeControlStatus == .playing { send(.ready) }
    }

    func setVolume(_ volume: Double) { player.volume = Float(min(1, max(0, volume))) }
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func setRate(_ rate: Double) {
        desiredRate = Float(rate)
        player.defaultRate = desiredRate
        if state == .playing { player.rate = desiredRate }
    }

    func setAudioOutput(uid: String?) {
        #if os(macOS)
        player.audioOutputDeviceUniqueID = uid
        #endif                                       // iOS: the system chooses the route (AirPlay, Bluetooth) in Control Center
    }

    private func teardown() {
        observer?.invalidate(); observer = nil
        if let item = player.currentItem, let out = videoOutput { item.remove(out) }
        videoOutput = nil
        player.replaceCurrentItem(with: nil)
        bridge?.stop(); bridge = nil
        audioGroup = nil; subtitleGroup = nil
        qualities = []; selectedQualityID = nil
    }

    // MARK: quality (real HLS renditions only)

    private func loadQualities(_ item: AVPlayerItem) async {
        guard let urlAsset = item.asset as? AVURLAsset, let variants = try? await urlAsset.load(.variants), variants.count > 1 else { qualities = []; return }
        var byHeight: [Int: Double] = [:]
        for v in variants {
            guard let h = v.videoAttributes?.presentationSize.height, h > 0 else { continue }
            byHeight[Int(h)] = max(byHeight[Int(h)] ?? 0, v.peakBitRate ?? 0)
        }
        qualities = byHeight.keys.sorted(by: >).map { QualityOption(id: "h\($0)", label: "\($0)p", height: $0, peakBitRate: byHeight[$0]) }
    }

    func qualityOptions() -> [QualityOption] { qualities }

    func selectQuality(id: String?) {
        guard let item = player.currentItem else { return }
        selectedQualityID = id
        if let id, let o = qualities.first(where: { $0.id == id }), let h = o.height {
            item.preferredMaximumResolution = CGSize(width: 16_384, height: CGFloat(h))
        } else {
            item.preferredMaximumResolution = .zero      // Auto: adaptive bitrate decides
            selectedQualityID = nil
        }
    }

    // MARK: tracks

    func availableAudioTracks() -> [AudioTrack] { tracks(for: audioGroup).map { AudioTrack(id: $0.id, label: $0.label, language: $0.language, isSelected: $0.selected) } }
    func availableSubtitleTracks() -> [SubtitleTrack] { tracks(for: subtitleGroup).map { SubtitleTrack(id: $0.id, label: $0.label, language: $0.language, isSelected: $0.selected) } }

    private func tracks(for group: AVMediaSelectionGroup?) -> [(id: String, label: String, language: String?, selected: Bool)] {
        guard let group, let item = player.currentItem else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { i, o in
            (String(i), o.displayName, o.locale?.language.languageCode?.identifier ?? o.extendedLanguageTag, o == selected)
        }
    }

    func selectAudioTrack(id: String?) { select(id, in: audioGroup) }
    func selectSubtitleTrack(id: String?) { select(id, in: subtitleGroup) }

    private func select(_ id: String?, in group: AVMediaSelectionGroup?) {
        guard let group, let item = player.currentItem else { return }
        if let id, let i = Int(id), group.options.indices.contains(i) { item.select(group.options[i], in: group) }
        else if group.allowsEmptySelection { item.select(nil, in: group) }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style
        player.currentItem?.textStyleRules = styleRules()
    }

    private func styleRules() -> [AVTextStyleRule] {
        let attrs: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: subtitleStyle.sizePercent,
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [subtitleStyle.backgroundOpacity, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, subtitleStyle.color.rgb.0, subtitleStyle.color.rgb.1, subtitleStyle.color.rgb.2],
        ]
        return AVTextStyleRule(textMarkupAttributes: attrs).map { [$0] } ?? []
    }

    // MARK: screenshot (current frame, where the stream allows it)

    func screenshot() -> CGImage? {
        guard let out = videoOutput, let item = player.currentItem else { return nil }
        let t = item.currentTime()
        guard let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}

private extension String {
    init(fourCC: FourCharCode) {
        let bytes = [UInt8((fourCC >> 24) & 255), UInt8((fourCC >> 16) & 255), UInt8((fourCC >> 8) & 255), UInt8(fourCC & 255)]
        self = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
