import Foundation
import AVFoundation
import MediaPlayer
import Observation

// The podcast player: audio only, its own AVPlayer, its own state. It never touches the library's PlaybackCoordinator, its engines or its history:
// the two sides only signal each other (starting one stops or pauses the other) through closures the shell connects.

struct PodcastChapter: Equatable, Identifiable, Sendable {
    var start: TimeInterval
    var title: String
    var id: TimeInterval { start }
}

struct PodcastTranscriptLine: Equatable, Identifiable, Sendable {
    var id: Int
    var start: TimeInterval?
    var text: String
}

/// Podcasting 2.0 side files: chapters (JSON) and transcripts (VTT, SRT or plain text).
enum PodcastExtras {
    static func parseChapters(_ data: Data) -> [PodcastChapter] {
        struct File: Decodable { struct C: Decodable { let startTime: Double; let title: String? }; let chapters: [C] }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.chapters.compactMap { c in c.title.map { PodcastChapter(start: c.startTime, title: $0) } }.sorted { $0.start < $1.start }
    }

    static func parseTranscript(_ data: Data) -> [PodcastTranscriptLine] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var out: [PodcastTranscriptLine] = []
        if text.contains("-->") {
            for block in text.components(separatedBy: "\n\n") {
                let lines = block.components(separatedBy: "\n")
                guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
                let start = time(String(lines[i].components(separatedBy: "-->")[0]))
                let body = lines[(i + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { out.append(PodcastTranscriptLine(id: out.count, start: start, text: PodcastParser.plain(body))) }
            }
        } else {
            for para in text.components(separatedBy: "\n\n") {
                let t = PodcastParser.plain(para).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(PodcastTranscriptLine(id: out.count, start: nil, text: t)) }
            }
        }
        return out
    }

    /// "00:01:02.500", "01:02,500" or "62.5".
    static func time(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 }
    }
}

enum PodcastSleep: Equatable, Sendable { case off, minutes(Int), endOfEpisode }

/// What plays the sound. The real one is an AVPlayer; tests use a fake.
@MainActor protocol PodcastAudioEngine: AnyObject {
    var onEnded: (() -> Void)? { get set }
    var position: TimeInterval { get }
    var duration: TimeInterval? { get }
    func load(_ url: URL, start: TimeInterval)
    func play(rate: Double)
    func pause()
    func setRate(_ rate: Double)
    func seek(to: TimeInterval)
    func setVolume(_ v: Double)
    func stop()
}

/// An AVPlayer with the speech-tuned time-stretch (pitch stays put from 0.5x to 3x).
@MainActor final class AVPodcastEngine: PodcastAudioEngine {
    private let player = AVPlayer()
    private var observer: NSObjectProtocol?
    var onEnded: (() -> Void)?

    var position: TimeInterval { let t = player.currentTime().seconds; return t.isFinite ? max(0, t) : 0 }
    var duration: TimeInterval? { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite && d > 0 ? d : nil }

    func load(_ url: URL, start: TimeInterval) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        player.replaceCurrentItem(with: item)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    }
    func play(rate: Double) { player.defaultRate = Float(rate); player.rate = Float(rate) }
    func pause() { player.pause() }
    func setRate(_ rate: Double) { player.defaultRate = Float(rate); if player.rate != 0 { player.rate = Float(rate) } }
    func seek(to t: TimeInterval) { player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func setVolume(_ v: Double) { player.volume = Float(v) }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
}

@MainActor @Observable
final class PodcastPlayer {
    let library: PodcastLibrary
    @ObservationIgnored private let engine: PodcastAudioEngine
    private(set) var current: PodcastEpisodeRef?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var speed = 1.0
    private(set) var chapters: [PodcastChapter] = []
    private(set) var transcript: [PodcastTranscriptLine] = []
    private(set) var sleep = PodcastSleep.off
    private(set) var sleepDeadline: Date?
    var volume = 1.0 { didSet { engine.setVolume(volume) } }
    /// The expanded Now Playing panel for podcasts; opens only when asked.
    var panelOpen = false

    /// Connected by the shell: starting a podcast stops the library's player and pauses services' media.
    @ObservationIgnored var stopLibrary: () -> Void = {}
    @ObservationIgnored var pauseServices: () -> Void = {}
    @ObservationIgnored var loadData: @Sendable (URL) async throws -> Data = { url in try await HTTPClient.app.exchange(URLRequest(url: url, timeoutInterval: 20)).data }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var lastSave: TimeInterval = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(library: PodcastLibrary, engine: PodcastAudioEngine? = nil, autoTick: Bool = true) {
        self.library = library
        self.engine = engine ?? AVPodcastEngine()
        self.engine.onEnded = { [weak self] in self?.ended() }
        if autoTick { ticker = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 500_000_000); self?.tick() } } }
    }

    // MARK: playing

    func play(_ ref: PodcastEpisodeRef) {
        saveNow()
        stopLibrary(); pauseServices()
        current = ref; position = library.startPosition(ref); duration = ref.duration ?? 0
        speed = library.speed(for: ref.feedURL)
        chapters = []; transcript = []
        engine.load(ref.audioURL, start: position)
        engine.play(rate: speed)
        isPlaying = true; lastSave = position
        library.setPosition(ref, position: position, duration: ref.duration)
        loadExtras(ref)
    }

    func pause() { guard current != nil, isPlaying else { return }; engine.pause(); isPlaying = false; saveNow() }
    func resume() { guard current != nil, !isPlaying else { return }; stopLibrary(); pauseServices(); engine.play(rate: speed); isPlaying = true }
    func toggle() { isPlaying ? pause() : resume() }

    /// The library's player (or a service) started: this one pauses.
    func otherMediaStarted() { pause() }

    func close() {
        saveNow(); engine.stop()
        current = nil; isPlaying = false; position = 0; duration = 0; panelOpen = false; chapters = []; transcript = []; sleep = .off; sleepDeadline = nil
    }

    func seek(to t: TimeInterval) {
        let target = duration > 0 ? min(max(0, t), duration) : max(0, t)
        position = target; engine.seek(to: target); saveNow()
    }
    func skipBack() { guard let c = current else { return }; seek(to: position - Double(library.skipBack(for: c.feedURL))) }
    func skipForward() { guard let c = current else { return }; seek(to: position + Double(library.skipForward(for: c.feedURL))) }

    /// A speed chosen in the player belongs to this show.
    func setSpeed(_ s: Double) {
        let v = min(3, max(0.5, s)); speed = v
        if let c = current { var st = library.settings(for: c.feedURL); st.speed = v; library.setSettings(st, for: c.feedURL) }
        engine.setRate(v)
    }
    func cycleSpeed() {
        let all = PodcastLibrary.speeds
        setSpeed(all.first { $0 > speed + 0.001 } ?? all[0])
    }

    /// The next in Up Next, or the end of listening.
    func next() {
        if let c = current { library.markPlayed(c, true) }
        if let n = library.popQueue() { play(n) } else { engine.pause(); isPlaying = false; position = 0; saveNow() }
    }

    func playChapter(_ c: PodcastChapter) { seek(to: c.start) }
    var currentChapter: PodcastChapter? { chapters.last { $0.start <= position + 0.5 } }

    // MARK: sleep

    func setSleep(_ s: PodcastSleep) {
        sleep = s
        if case .minutes(let m) = s { sleepDeadline = now().addingTimeInterval(Double(m) * 60) } else { sleepDeadline = nil }
    }

    // MARK: ticking

    func tick() {
        guard let c = current else { return }
        if isPlaying {
            position = engine.position
            if let d = engine.duration { duration = d }
            if position - lastSave >= 5 || position < lastSave { saveNow() }
        }
        if let deadline = sleepDeadline, now() >= deadline { sleep = .off; sleepDeadline = nil; pause() }
        _ = c
    }

    /// The episode reached its end: it is played; with the sleep timer on "end of episode" playback stops, else Up Next goes on.
    func ended() {
        guard let c = current else { return }
        library.markPlayed(c, true)
        if sleep == .endOfEpisode { sleep = .off; isPlaying = false; engine.pause(); position = 0; return }
        if let n = library.popQueue() { play(n) } else { isPlaying = false; position = 0 }
    }

    private func saveNow() {
        guard let c = current else { return }
        if isPlaying { position = engine.position }
        lastSave = position
        if library.isPlayed(c.itemID) && position == 0 { return }
        library.setPosition(c, position: position, duration: duration > 0 ? duration : nil)
    }

    private func loadExtras(_ ref: PodcastEpisodeRef) {
        let loader = loadData
        if let u = ref.chaptersURL { Task { [weak self] in
            guard let data = try? await loader(u) else { return }
            let list = PodcastExtras.parseChapters(data)
            if self?.current?.itemID == ref.itemID { self?.chapters = list }
        } }
        if let u = ref.transcriptURL { Task { [weak self] in
            guard let data = try? await loader(u) else { return }
            let list = PodcastExtras.parseTranscript(data)
            if self?.current?.itemID == ref.itemID { self?.transcript = list }
        } }
    }

    // MARK: Now Playing

    var snapshot: PodcastNowPlayingSnapshot? {
        guard let c = current else { return nil }
        return PodcastNowPlayingSnapshot(title: c.title, show: c.showTitle, isPlaying: isPlaying, position: position, duration: duration > 0 ? duration : nil, speed: speed,
                                         skipBack: library.skipBack(for: c.feedURL), skipForward: library.skipForward(for: c.feedURL), hasNext: !library.queue.isEmpty, artworkURL: c.artwork?.absoluteString)
    }
}

/// What the media keys, Control Centre and the lock screen are told about a podcast: audio, with the real playback rate.
struct PodcastNowPlayingSnapshot: Equatable {
    var title: String
    var show: String
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval?
    var speed: Double
    var skipBack: Int
    var skipForward: Int
    var hasNext: Bool
    var artworkURL: String?

    var info: [String: Any] {
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: show, MPMediaItemPropertyAlbumTitle: show,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, position),
        ]
        if let duration, duration > 0 { d[MPMediaItemPropertyPlaybackDuration] = duration }
        return d
    }
}

/// Registers the podcast player with the system's media keys and Now Playing, and keeps it up to date. It only answers while a podcast is the thing playing.
@MainActor final class PodcastRemote {
    private weak var player: PodcastPlayer?
    private let artwork: ArtworkService?
    private var task: Task<Void, Never>?
    private var artworkFor: String?
    private var artworkItem: MPMediaItemArtwork?
    private var published = false
    var isLocked: () -> Bool = { false }

    init(player: PodcastPlayer, artwork: ArtworkService?) {
        self.player = player; self.artwork = artwork
        register()
        task = Task { [weak self] in while !Task.isCancelled { self?.refresh(); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
    }
    deinit { task?.cancel() }

    func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let s = player?.snapshot, !isLocked() else {
            if published { center.nowPlayingInfo = nil; center.playbackState = .stopped; published = false; artworkItem = nil; artworkFor = nil }
            return
        }
        var info = s.info
        if artworkFor == s.artworkURL, let artworkItem { info[MPMediaItemPropertyArtwork] = artworkItem }
        center.nowPlayingInfo = info
        center.playbackState = s.isPlaying ? .playing : .paused
        published = true
        let r = MPRemoteCommandCenter.shared()
        r.playCommand.isEnabled = true; r.pauseCommand.isEnabled = true; r.togglePlayPauseCommand.isEnabled = true
        r.skipForwardCommand.isEnabled = true; r.skipBackwardCommand.isEnabled = true; r.changePlaybackPositionCommand.isEnabled = true
        r.skipForwardCommand.preferredIntervals = [NSNumber(value: s.skipForward)]; r.skipBackwardCommand.preferredIntervals = [NSNumber(value: s.skipBack)]
        r.nextTrackCommand.isEnabled = s.hasNext; r.previousTrackCommand.isEnabled = true
        if artworkFor != s.artworkURL { loadArtwork(s.artworkURL) }
    }

    private func loadArtwork(_ url: String?) {
        artworkFor = url; artworkItem = nil
        guard let url, !url.isEmpty, let artwork else { return }
        Task { [weak self] in
            guard let image = await artwork.image(url, kind: .poster) else { return }
            let item = NowPlayingService.makeArtwork(image)
            await MainActor.run {
                guard let self, self.artworkFor == url, self.player?.current != nil else { return }
                self.artworkItem = item
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = item
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func register() {
        let r = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping @MainActor (PodcastPlayer, MPRemoteCommandEvent) -> Void) {
            _ = cmd.addTarget { [weak self] event in
                guard let p = MainActor.assumeIsolated({ self?.player }), MainActor.assumeIsolated({ p.current != nil }) else { return .noActionableNowPlayingItem }
                if MainActor.assumeIsolated({ self?.isLocked() == true }) { return .commandFailed }
                MainActor.assumeIsolated { handler(p, event) }
                return .success
            }
        }
        add(r.playCommand) { p, _ in p.resume() }
        add(r.pauseCommand) { p, _ in p.pause() }
        add(r.togglePlayPauseCommand) { p, _ in p.toggle() }
        add(r.skipForwardCommand) { p, _ in p.skipForward() }
        add(r.skipBackwardCommand) { p, _ in p.skipBack() }
        add(r.nextTrackCommand) { p, _ in p.next() }
        add(r.previousTrackCommand) { p, _ in p.seek(to: 0) }
        add(r.changePlaybackPositionCommand) { p, e in if let e = e as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) } }
    }
}
