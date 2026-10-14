import CoreImage
import AVFoundation
import CoreMedia
import CoreVideo

/// libmpv engine for containers AVPlayer can't open (MKV, RTSP, DASH, odd codecs). Frames are decoded by mpv
/// (VideoToolbox hardware decoding where possible), rendered in software into a pixel buffer and shown through
/// an `AVSampleBufferDisplayLayer`. Authentication failures and DRM are reported, never worked around.
@MainActor
final class MPVPlayerEngine: PlaybackEngine {
    static var isAvailable: Bool { MPVLibrary.shared.isAvailable }

    let kind = PlaybackEngineKind.mpv
    let capabilities = PlaybackCapabilities(containers: [.hls, .mp4, .mpegTS, .mkv, .rtsp, .dash], pictureInPicture: false, airPlay: false, screenshot: true,
                                            audioDelay: true, audioProcessing: true, subtitleDelay: true, subtitlePosition: true,
                                            externalSubtitles: true, liveRewind: true, pictureAdjustments: true, chapters: true, abLoop: true, frameStep: true, volumeBoost: true)
    var bufferingMode: BufferingMode = .automatic
    var qualityPreference: VideoQualityPreference = .automatic
    var configuration = MPVConfiguration()
    let displayLayer = AVSampleBufferDisplayLayer()
    /// iPhone and iPad show MPV's frames by handing each finished frame's surface to a plain layer. (The sample-buffer display layer
    /// was fed fine on iOS but showed nothing; this path has no timing or format negotiation to go wrong.)
    let surfaceLayer = CALayer()
    /// While a live web stream plays on a phone, the local relay that fetches it for MPV (see TSBridge.Mode.raw).
    private var relay: TSBridge?
    /// The last "Connection to tcp://HOST:PORT failed: …" mpv logged: which server could not be reached, and why.
    private var lastConnectFailure: (host: String, reason: String)?
    private let ciContext = CIContext()
    private(set) var lastHTTPStatus: Int?
    private(set) var metrics = PlaybackMetrics(engine: .mpv)

    let stateUpdates: AsyncStream<PlaybackState>
    private let continuation: AsyncStream<PlaybackState>.Continuation
    private var machine = PlaybackStateMachine()
    var state: PlaybackState { machine.state }

    private let lib = MPVLibrary.shared
    private var core: Core?
    private var request: PlaybackRequest?
    private var workers: [Task<Void, Never>] = []
    private var userPaused = false
    private var buffering = BufferingMonitor()
    private var lastFrame: CGImage?

    /// All raw libmpv state; touched from the event thread and the render queue, so it is a locked reference type.
    private final class Core: @unchecked Sendable {
        let ctx: OpaquePointer
        var render: OpaquePointer?
        nonisolated(unsafe) var tracedFrames = 0
        let renderQueue = DispatchQueue(label: "app.reddy.mpv.render", qos: .userInteractive)
        var layer: AVSampleBufferDisplayLayer?
        /// Taken on the main actor once, so the render thread never touches the layer's main-actor property.
        nonisolated(unsafe) var renderer: AVSampleBufferVideoRenderer?
        nonisolated(unsafe) var surface: CALayer?
        /// While Picture in Picture is on, finished frames also go to the sample-buffer layer that feeds it (iPhone and iPad only).
        nonisolated(unsafe) var pipFeed = false
        /// The newest frame, kept as the buffer it was drawn into; a picture is only made from it when a screenshot is asked for.
        nonisolated(unsafe) var latestBuffer: CVPixelBuffer?
        var stopped = false
        /// Signalled when the event thread has left `mpv_wait_event` for good. The context may only be destroyed after that.
        let eventThreadDone = DispatchSemaphore(value: 0)
        var eventThreadRunning = false
        init(ctx: OpaquePointer) { self.ctx = ctx }
    }

    init() {
        (stateUpdates, continuation) = AsyncStream.makeStream(of: PlaybackState.self, bufferingPolicy: .bufferingNewest(8))
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        surfaceLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        surfaceLayer.contentsGravity = .resizeAspect
        surfaceLayer.isOpaque = true
    }

    private func send(_ e: PlaybackEvent) {
        let before = machine.state
        if machine.send(e), machine.state != before { continuation.yield(machine.state) }
    }

    // MARK: lifecycle

    func load(_ request: PlaybackRequest) async throws {
        guard lib.isAvailable else { let e = PlaybackError(.engineUnavailable); send(.startResolving); send(.failed(e)); throw e }
        teardown()
        self.request = request
        lastHTTPStatus = nil; userPaused = false; lastConnectFailure = nil; loadBegan = Date()
        send(.startResolving); send(.resolved)
        metrics = PlaybackMetrics(engine: .mpv, container: StreamCapabilities.container(for: request.url, isLive: request.isLive), host: request.url.host ?? "")
        loadedLive = request.isLive; steppedUp = false
        buffering.reset()

        guard let create = lib.create, let ctx = create() else { throw fail(PlaybackError(.engineUnavailable)) }
        let core = Core(ctx: ctx)
        core.layer = displayLayer
        core.renderer = displayLayer.sampleBufferRenderer
        core.surface = surfaceLayer
        self.core = core
        let rotationFilter: String? = request.url.isFileURL ? LocalMedia.rotationFilter(await LocalMedia.rotationDegrees(of: request.url)) : nil
        var cfg = configuration
        cfg.lowLatency = bufferingMode == .lowLatency
        cfg.isLive = request.isLive
        cfg.requestHeaders = request.headers
        cfg.resumeThreshold = bufferingMode.mpvResumeThreshold(live: request.isLive)
        for (k, v) in cfg.options where k != "vo" { _ = lib.setOption?(ctx, k, v == "videotoolbox" ? "videotoolbox-copy" : v) }
        _ = lib.setOption?(ctx, "vo", "libmpv")
        // The software renderer cannot draw a picture MPV rotates by itself (it aborts), so MPV's own rotation is off and a phone video that is stored
        // sideways is turned by a filter instead.
        _ = lib.setOption?(ctx, "video-rotate", "no")
        if let filter = rotationFilter { _ = lib.setOption?(ctx, "vf", filter) }
        _ = lib.requestLog?(ctx, "error")
        guard lib.initialize?(ctx) == 0 else { throw fail(PlaybackError(.engineUnavailable, detail: "mpv failed to initialise")) }
        try createRenderContext(core)
        startEventLoop(core)

        var target = request.url
        if Self.shouldRelay(request) {
            // The system's network stack fetches the stream; MPV reads it from this device. A failure to start falls back to MPV's own connection.
            let r = TSBridge(source: request.url, headers: request.headers, mode: .raw)
            if let local = try? await r.start() { relay = r; target = local; Trace.log("relay on for \(Trace.describe(request.url)) -> \(local.absoluteString)") }
            else { r.stop(); Trace.log("relay could not start; MPV connects directly") }
        }
        var args: [String] = ["loadfile", target.absoluteString, "replace"]
        if request.startPosition > 5, !request.isLive { args += ["-1", "start=\(Int(request.startPosition))"] }
        try run(args, core: core)
    }

    /// Live web streams of MPEG-TS go through the relay on iPhone and iPad (set STREAMSETU_RELAY=1 to try it on a Mac).
    static func shouldRelay(_ r: PlaybackRequest) -> Bool {
        #if os(iOS)
        let on = ProcessInfo.processInfo.environment["STREAMSETU_RELAY"] != "0"
        #else
        let on = ProcessInfo.processInfo.environment["STREAMSETU_RELAY"] == "1"
        #endif
        guard on, r.isLive, ["http", "https"].contains(r.url.scheme?.lowercased() ?? "") else { return false }
        return StreamCapabilities.container(for: r.url, isLive: true) == .mpegTS
    }

    /// Reads "[tcp] Connection to tcp://host:80 failed: Can't assign requested address" into the host and the reason.
    nonisolated static func connectFailure(in line: String) -> (host: String, reason: String)? {
        guard let r = line.range(of: "Connection to tcp://"), let end = line.range(of: " failed: ", range: r.upperBound..<line.endIndex) else { return nil }
        let hostPort = line[r.upperBound..<end.lowerBound]
        let host = hostPort.split(separator: ":").first.map(String.init) ?? String(hostPort)
        return (host, String(line[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func fail(_ e: PlaybackError) -> PlaybackError { send(.failed(e)); return e }

    private func run(_ args: [String], core: Core) throws {
        var cStrings: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for p in cStrings { free(UnsafeMutableRawPointer(mutating: p)) } }
        let rc = cStrings.withUnsafeMutableBufferPointer { lib.command?(core.ctx, $0.baseAddress) } ?? -1
        if rc < 0 { throw fail(PlaybackError(.unknown, detail: lib.errorMessage(rc))) }
    }

    func play() async throws {
        guard let core else { return }
        userPaused = false
        _ = lib.setProperty?(core.ctx, "pause", "no")
        if state == .paused { send(.resume) }
    }

    func pause() {
        guard let core else { return }
        userPaused = true
        _ = lib.setProperty?(core.ctx, "pause", "yes")
        send(.pause)
    }

    func stop() { teardown(); request = nil; send(.stop) }

    func seek(to position: TimeInterval) async throws {
        guard let core else { return }
        send(.seekBegan)
        try run(["seek", String(max(0, position)), "absolute"], core: core)
        send(.seekEnded)
        if userPaused { send(.pause) }
    }

    func setVolume(_ v: Double) { if let c = core { _ = lib.setProperty?(c.ctx, "volume", String(Int(min(1.3, max(0, v)) * 100))) } }
    func setMuted(_ m: Bool) { if let c = core { _ = lib.setProperty?(c.ctx, "mute", m ? "yes" : "no") } }
    func setRate(_ r: Double) { if let c = core { _ = lib.setProperty?(c.ctx, "speed", String(r)) } }

    private func teardown() {
        relay?.stop(); relay = nil
        workers.forEach { $0.cancel() }; workers = []
        guard let core else { return }
        core.stopped = true
        // The event thread may be blocked inside mpv_wait_event on this context. Destroying the context underneath it is a
        // use-after-free (libmpv aborts in ta_set_parent), so wake it and wait until it has really left before going on.
        if core.eventThreadRunning {
            lib.wakeup?(core.ctx)
            if core.eventThreadDone.wait(timeout: .now() + 3) == .timedOut {
                self.core = nil
                return
            }
        }
        core.renderQueue.sync {
            if let r = core.render { lib.renderSetCallback?(r, nil, nil); lib.renderFree?(r); core.render = nil }
        }
        lib.terminateDestroy?(core.ctx)
        self.core = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        CATransaction.begin(); CATransaction.setDisableActions(true); surfaceLayer.contents = nil; CATransaction.commit()
    }

    // MARK: rendering (software)

    private func createRenderContext(_ core: Core) throws {
        let apiType = strdup("sw")
        defer { free(apiType) }
        var params = [mpv_render_param(type: MPVConst.renderAPIType, data: UnsafeMutableRawPointer(apiType)), mpv_render_param(type: 0, data: nil)]
        var rc: OpaquePointer?
        let status = params.withUnsafeMutableBufferPointer { lib.renderCreate?(&rc, core.ctx, UnsafeMutableRawPointer($0.baseAddress)) } ?? -1
        guard status == 0, let rc else { throw fail(PlaybackError(.engineUnavailable, detail: lib.errorMessage(status))) }
        core.render = rc
        let box = Unmanaged.passRetained(core)
        MPVLibrary.shared.renderSetCallback?(rc, { ptr in
            guard let ptr else { return }
            let core = Unmanaged<Core>.fromOpaque(ptr).takeUnretainedValue()
            core.renderQueue.async { MPVPlayerEngine.renderFrame(core) }
        }, box.toOpaque())
    }

    /// A frame's surface and the layer it goes on, moved to the main thread in one piece.
    private struct SurfaceBox: @unchecked Sendable { let io: IOSurfaceRef; let layer: CALayer }

    #if os(iOS)
    nonisolated private static let trcPath = "CALayer(IOSurface)"
    #else
    nonisolated private static let trcPath = "AVSampleBufferDisplayLayer"
    #endif

    nonisolated private static func renderFrame(_ core: Core) {
        let lib = MPVLibrary.shared
        guard !core.stopped, let render = core.render else { return }
        guard (lib.renderUpdate?(render) ?? 0) & MPVConst.updateFrame != 0 else { return }
        var w: Int64 = 0, h: Int64 = 0
        _ = lib.getProperty?(core.ctx, "dwidth", MPVConst.formatInt64, &w)
        _ = lib.getProperty?(core.ctx, "dheight", MPVConst.formatInt64, &h)
        #if os(iOS)
        // Never draw more than 1920 pixels across on a phone: a 4K picture would cost four times the work for no visible gain.
        if max(w, h) > 1920 { let k = 1920.0 / Double(max(w, h)); w = Int64(Double(w) * k) & ~1; h = Int64(Double(h) * k) & ~1 }
        #endif
        guard w > 0, h > 0, w * h < 40_000_000 else { Trace.log("mpv render skipped: size \(w)x\(h)"); return }

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(w), Int(h), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        var size: [Int32] = [Int32(w), Int32(h)]
        var stride = CVPixelBufferGetBytesPerRow(pb)
        let fmt = strdup("bgr0")
        defer { free(fmt) }
        var rc: Int32 = -1
        size.withUnsafeMutableBytes { sz in
            var params = [mpv_render_param(type: MPVConst.renderSWSize, data: sz.baseAddress),
                          mpv_render_param(type: MPVConst.renderSWFormat, data: UnsafeMutableRawPointer(fmt)),
                          mpv_render_param(type: MPVConst.renderSWStride, data: withUnsafeMutablePointer(to: &stride) { UnsafeMutableRawPointer($0) }),
                          mpv_render_param(type: MPVConst.renderSWPointer, data: CVPixelBufferGetBaseAddress(pb)),
                          mpv_render_param(type: 0, data: nil)]
            rc = params.withUnsafeMutableBufferPointer { lib.renderRender?(render, UnsafeMutableRawPointer($0.baseAddress)) } ?? -1
        }
        var brightness = -1.0
        if Trace.on, rc >= 0, core.tracedFrames == 0 || (core.tracedFrames + 1) % 120 == 0, let base = CVPixelBufferGetBaseAddress(pb) {
            // Mean brightness of 400 sampled pixels (0 = black, 255 = white), to tell a black picture from a picture that is not shown.
            var total = 0.0, n = 0.0
            let bytes = base.assumingMemoryBound(to: UInt8.self), rowBytes = CVPixelBufferGetBytesPerRow(pb)
            for yi in 0..<20 { for xi in 0..<20 {
                let px = bytes + (Int(h) * (yi * 2 + 1) / 41) * rowBytes + (Int(w) * (xi * 2 + 1) / 41) * 4
                total += (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3; n += 1
            } }
            brightness = total / n
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard rc >= 0 else { Trace.log("mpv render FAILED rc=\(rc) size=\(w)x\(h)"); return }

        core.latestBuffer = pb
        #if os(iOS)
        if let io = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue(), let layer = core.surface {
            let box = SurfaceBox(io: io, layer: layer)
            DispatchQueue.main.async { CATransaction.begin(); CATransaction.setDisableActions(true); box.layer.contents = box.io; CATransaction.commit() }
        }
        if core.pipFeed { enqueueForPiP(pb, core) }
        #else
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            att.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        core.renderer?.enqueue(sb)
        #endif
        core.tracedFrames += 1
        if core.tracedFrames == 1 || (Trace.on && core.tracedFrames % 120 == 0) {
            do {
                Trace.log("mpv frame #\(core.tracedFrames) \(w)x\(h) brightness=\(String(format: "%.1f", brightness)) path=\(Self.trcPath)")
            }
        }
    }

    #if os(iOS)
    /// The same frame, as a sample buffer for the layer behind Picture in Picture.
    nonisolated private static func enqueueForPiP(_ pb: CVPixelBuffer, _ core: Core) {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            att.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        core.renderer?.enqueue(sb)
    }
    #endif

    /// Starts or stops feeding frames to the Picture in Picture layer.
    func setPiPFeed(_ on: Bool) {
        #if os(iOS)
        core?.pipFeed = on
        if !on { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
        #endif
    }

    // MARK: events & polling

    private struct MPVEvent: Sendable { let id: Int32; let reason: Int32; let error: Int32; let text: String? }

    private func startEventLoop(_ core: Core) {
        let lib = self.lib
        let stream = AsyncStream<MPVEvent> { cont in
            core.eventThreadRunning = true
            let thread = Thread {
                defer { core.eventThreadDone.signal() }
                while !core.stopped {
                    guard let raw = lib.waitEvent?(core.ctx, 0.3) else { continue }
                    let ev = raw.assumingMemoryBound(to: mpv_event.self).pointee
                    if ev.event_id == MPVConst.evShutdown { break }
                    switch ev.event_id {
                    case MPVConst.evEndFile:
                        let d = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        cont.yield(MPVEvent(id: ev.event_id, reason: d?.reason ?? -1, error: d?.error ?? 0, text: nil))
                    case MPVConst.evLog:
                        if let d = ev.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee, let t = d.text {
                            cont.yield(MPVEvent(id: ev.event_id, reason: 0, error: 0, text: String(cString: t)))
                        }
                    case MPVConst.evStartFile, MPVConst.evFileLoaded, MPVConst.evPlaybackRestart:
                        cont.yield(MPVEvent(id: ev.event_id, reason: 0, error: 0, text: nil))
                    default: break
                    }
                }
                cont.finish()
            }
            thread.name = "app.reddy.mpv.events"
            thread.start()
        }
        let events = Task { @MainActor [weak self] in
            for await e in stream { self?.handle(e) }
        }
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tick()
            }
        }
        workers = [events, ticker]
    }

    private func handle(_ e: MPVEvent) {
        switch e.id {
        case MPVConst.evFileLoaded: send(.buffering)
        case MPVConst.evPlaybackRestart:
            do { Trace.log("mpv playback-restart video=\(string("video-format") ?? "-") size=\(int("width") ?? 0)x\(int("height") ?? 0) hwdec=\(string("hwdec-current") ?? "-") pix=\(string("video-params/pixelformat") ?? "-") gamma=\(string("video-params/gamma") ?? "-") primaries=\(string("video-params/primaries") ?? "-") fps=\(double("container-fps").map { String(format: "%.1f", $0) } ?? "-") audio=\(string("audio-codec-name") ?? "-") dropped=\(int("frame-drop-count") ?? 0)") }
            buffering.playing(); metrics.startupSeconds = metrics.startupSeconds ?? buffering.startupSeconds
            if userPaused { send(.pause) } else { send(.ready) }
        case MPVConst.evLog:
            if let t = e.text {
                Trace.log("mpv: \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
                if let f = Self.connectFailure(in: t) { lastConnectFailure = f }
            }
            if let t = e.text, let status = [401, 403, 404, 405, 429, 500, 502, 503].first(where: { t.contains("HTTP error \($0)") || t.contains(" \($0) ") && t.contains("HTTP") }) { lastHTTPStatus = status }
        case MPVConst.evEndFile:
            switch e.reason {
            case MPVConst.endEOF:
                if request?.isLive == true { send(.failed(PlaybackError(.network, detail: "The live stream ended."))) } else { send(.reachedEnd) }
            case MPVConst.endError:
                Trace.log("mpv end-file error code=\(e.error) (\(lib.errorMessage(e.error))) lastHTTP=\(lastHTTPStatus.map(String.init) ?? "-")")
                let err: PlaybackError
                if let r = relay, r.receivedNothing { err = PlaybackError(.providerBusy) }                           // the provider sent no video at all
                else if let r = relay, let st = r.httpStatus, st != 200 { err = .fromHTTP(st) }
                else if let f = lastConnectFailure, PlaybackError.unreachableAddressReasons.contains(where: { f.reason.contains($0) }) { err = PlaybackError(.nameLookup, detail: f.host) }
                else if let s = lastHTTPStatus { err = .fromHTTP(s) }
                else if (e.error == MPVConst.errUnknownFormat || e.error == MPVConst.errNothingToPlay), request?.isLive == true, request?.url.scheme?.hasPrefix("http") == true {
                    // MPV reads any live format, so "nothing to play" on a live web stream means the server sent nothing: its connection limit, not a codec.
                    err = PlaybackError(.providerBusy)
                }
                else if (e.error == MPVConst.errUnknownFormat || e.error == MPVConst.errNothingToPlay), request?.isLive == false, request?.url.scheme?.hasPrefix("http") == true,
                        Date().timeIntervalSince(loadBegan) < 0.6 {
                    // A movie "recognised" as nothing within a fraction of a second never received a byte (reaching the provider takes longer than that):
                    // it answered with an empty reply, which is a title it isn't serving, not a format MPV cannot read.
                    err = PlaybackError(.providerBusy)
                }
                else if e.error == MPVConst.errUnknownFormat || e.error == MPVConst.errNothingToPlay { err = PlaybackError(.unsupportedFormat) }
                else if e.error == MPVConst.errLoadingFailed { err = PlaybackError(.providerUnavailable) }
                else { err = PlaybackError(.unknown, detail: lib.errorMessage(e.error)) }
                send(.failed(err))
            default: break
            }
        default: break
        }
    }

    private func double(_ name: String) -> Double? {
        guard let c = core else { return nil }
        var v = 0.0
        return lib.getProperty?(c.ctx, name, MPVConst.formatDouble, &v) == 0 ? v : nil
    }
    private func int(_ name: String) -> Int? {
        guard let c = core else { return nil }
        var v: Int64 = 0
        return lib.getProperty?(c.ctx, name, MPVConst.formatInt64, &v) == 0 ? Int(v) : nil
    }
    private func flag(_ name: String) -> Bool? {
        guard let c = core else { return nil }
        var v: Int32 = 0
        return lib.getProperty?(c.ctx, name, MPVConst.formatFlag, &v) == 0 ? v != 0 : nil
    }
    private func string(_ name: String) -> String? {
        guard let c = core, let p = lib.getPropertyString?(c.ctx, name) else { return nil }
        defer { lib.free?(p) }
        return String(cString: p)
    }

    private func tick() {
        if let w = int("dwidth"), let h = int("dheight") { metrics.width = w; metrics.height = h }
        if let b = double("video-bitrate") { metrics.observedBitrate = b }
        if let d = int("frame-drop-count") { metrics.droppedFrames = d }
        if let c = double("demuxer-cache-time"), let p = double("time-pos") { metrics.bufferedAheadSeconds = max(0, c - p) }
        metrics.videoCodec = string("video-codec") ?? metrics.videoCodec
        metrics.audioCodec = string("audio-codec-name") ?? metrics.audioCodec
        if flag("paused-for-cache") == true, state == .playing { buffering.bufferingBegan(); send(.buffering) }
        else if flag("paused-for-cache") == false, state == .buffering, !userPaused, int("dwidth") != nil { buffering.playing(); send(.ready) }
        metrics.stallCount = buffering.stalls; metrics.totalStallSeconds = buffering.stalledSeconds
        if buffering.stalls >= 2, !loadedLive, !steppedUp, bufferingMode == .automatic { stepUpBuffering() }
    }

    private var loadedLive = false
    private var steppedUp = false
    private var loadBegan = Date()

    /// A movie or episode that has run dry twice is on a line slower than its bitrate. Restarting after 1.5 s of data would only stall
    /// again, so it now waits for a deeper buffer (the Stability values) between pauses. Changed while playing, no restart.
    private func stepUpBuffering() {
        guard let c = core else { return }
        steppedUp = true
        for (k, v) in [("cache-secs", "60"), ("demuxer-readahead-secs", "60"), ("demuxer-max-bytes", "192MiB"), ("cache-pause-wait", "8")] { _ = lib.setProperty?(c.ctx, k, v) }
        Trace.log("buffering stepped up after \(buffering.stalls) stalls (60 s buffer, resume after 8 s)")
    }

    var position: TimeInterval { double("time-pos") ?? 0 }
    var duration: TimeInterval? { double("duration").flatMap { $0 > 0 ? $0 : nil } }

    // MARK: tracks

    private func tracks(_ type: String) -> [(id: String, label: String, lang: String?, selected: Bool)] {
        let n = int("track-list/count") ?? 0
        return (0..<n).compactMap { i in
            guard string("track-list/\(i)/type") == type, let id = int("track-list/\(i)/id") else { return nil }
            let lang = string("track-list/\(i)/lang"), title = string("track-list/\(i)/title")
            let label = [title, lang.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }].compactMap { $0 }.first ?? "Track \(id)"
            return (String(id), label, lang, flag("track-list/\(i)/selected") ?? false)
        }
    }

    func availableAudioTracks() -> [AudioTrack] { tracks("audio").map { AudioTrack(id: $0.id, label: $0.label, language: $0.lang, isSelected: $0.selected) } }
    func availableSubtitleTracks() -> [SubtitleTrack] { tracks("sub").map { SubtitleTrack(id: $0.id, label: $0.label, language: $0.lang, isSelected: $0.selected) } }
    func selectAudioTrack(id: String?) { if let c = core { _ = lib.setProperty?(c.ctx, "aid", id ?? "no") } }
    func selectSubtitleTrack(id: String?) { if let c = core { _ = lib.setProperty?(c.ctx, "sid", id ?? "no") } }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        guard let c = core else { return }
        _ = lib.setProperty?(c.ctx, "sub-scale", String(style.sizePercent / 100))
        _ = lib.setProperty?(c.ctx, "sub-back-color", "#\(String(format: "%02X", Int(style.backgroundOpacity * 255)))000000")
        _ = lib.setProperty?(c.ctx, "sub-color", style.color.hex)
        _ = lib.setProperty?(c.ctx, "sub-pos", String(Int(100 - style.verticalPosition * 100)))
        _ = lib.setProperty?(c.ctx, "sub-border-size", style.outline ? "3" : "0")
        _ = lib.setProperty?(c.ctx, "sub-shadow-offset", style.outline ? "1" : "0")
    }

    func screenshot() -> CGImage? {
        guard let pb = core?.latestBuffer else { return nil }
        return ciContext.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
    }

    func chapters() -> [PlaybackChapter] {
        let n = int("chapter-list/count") ?? 0
        guard n > 1 else { return [] }
        return (0..<min(n, 200)).compactMap { i in
            guard let t = double("chapter-list/\(i)/time") else { return nil }
            let title = string("chapter-list/\(i)/title")?.trimmingCharacters(in: .whitespaces)
            return PlaybackChapter(time: t, title: (title?.isEmpty == false ? title! : "Chapter \(i + 1)"))
        }
    }

    func setLoop(start: Double?, end: Double?) {
        guard let c = core else { return }
        _ = lib.setProperty?(c.ctx, "ab-loop-a", start.map { String($0) } ?? "no")
        _ = lib.setProperty?(c.ctx, "ab-loop-b", end.map { String($0) } ?? "no")
    }

    func frameStep(forward: Bool) {
        guard let c = core else { return }
        var cStrings: [UnsafePointer<CChar>?] = [forward ? "frame-step" : "frame-back-step", nil].map { $0.flatMap { UnsafePointer(strdup($0)) } }
        defer { for p in cStrings { free(UnsafeMutableRawPointer(mutating: p)) } }
        _ = cStrings.withUnsafeMutableBufferPointer { lib.command?(c.ctx, $0.baseAddress) }
        userPaused = true
        send(.pause)
    }

    /// Loads a subtitle file and switches to it. mpv detects the text encoding itself (`sub-codepage`), so older files in
    /// Windows-1252, ISO-8859 and similar still show their accents.
    /// How far the live buffer reaches: mpv's cached range ends here.
    var liveBufferEnd: TimeInterval? {
        guard let c = core, let p = lib.getPropertyString?(c.ctx, "demuxer-cache-time") else { return nil }
        defer { lib.free?(p) }
        return Double(String(cString: p))
    }

    func addSubtitleFile(_ url: URL) -> Bool {
        guard let c = core else { return false }
        do { try run(["sub-add", url.path, "select"], core: c); return true } catch { return false }
    }

    func setPicture(_ p: PictureAdjustments) {
        guard let c = core else { return }
        let v = p.clamped()
        for (name, value) in [("brightness", v.brightness), ("contrast", v.contrast), ("saturation", v.saturation), ("gamma", v.gamma), ("hue", v.hue)] {
            _ = lib.setProperty?(c.ctx, name, String(value))
        }
    }

    func setAudioDelay(_ seconds: Double) { if let c = core { _ = lib.setProperty?(c.ctx, "audio-delay", String(seconds)) } }
    func setSubtitleDelay(_ seconds: Double) { if let c = core { _ = lib.setProperty?(c.ctx, "sub-delay", String(seconds)) } }

    /// Loudness handling through FFmpeg's lavfi filters (mpv `af`).
    func setAudioProcessing(_ mode: AudioProcessingMode) {
        guard let c = core else { return }
        let filter: String
        switch mode {
        case .off: filter = ""
        case .standard: filter = "lavfi=[dynaudnorm=f=250:g=15]"
        case .nightMode: filter = "lavfi=[acompressor=threshold=-24dB:ratio=4:attack=20:release=300:makeup=2]"
        }
        _ = lib.setProperty?(c.ctx, "af", filter)
    }
}
