import Foundation
import Observation

// The editor's working state: the draft, the line being timed, the tap pass, the loop that keeps playing it, drafts on disk and sending.
// The player is touched only while the editor is open, and the person's own playback speed is put back when it closes.

@MainActor @Observable
final class MusicLyricsEditorModel {
    enum Step: Int, CaseIterable, Sendable { case text = 1, timing, send
        var title: String { switch self { case .text: "Text"; case .timing: "Timing"; case .send: "Send" } }
    }

    enum SendState: Equatable {
        case idle, sending
        case done(MusicLyricsReceipt)
        case failed(MusicLyricsSubmissionError)
    }

    let track: MusicTrack
    let videoID: String
    let player: MusicPlayer
    private let drafts: MusicLyricsDraftStore
    private let client: MusicLyricsSubmissionClient

    var draft: MusicLyricsDraft { didSet { scheduleSave() } }
    var step: Step = .text
    var selectedID: Int?
    var pass: MusicLyricsTapPass?
    var backgroundPass = false
    var loopOn = true
    var tempo = MusicLyricsTapMath.defaultTempo { didSet { applyTempo() } }
    var tapOffsetMs: Double = 0 { didSet { tapOffsetMs = MusicLyricsTapMath.clampTapOffset(tapOffsetMs); UserDefaults.standard.set(tapOffsetMs, forKey: Self.offsetKey) } }
    var previewing = false { didSet { applyTempo() } }
    var banner: String?
    var notice: String?
    var send: SendState = .idle
    var rejection: (reason: String, revision: Int)?
    var celebrated = false

    static let offsetKey = "music.lyrics.editor.tapOffsetMs"
    static let tempoKey = "music.lyrics.editor.tempo"

    @ObservationIgnored private var userTempo: Double?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sample: (position: Double, wall: Double, speed: Double, paused: Bool) = (0, 0, 1, true)
    @ObservationIgnored private var wasReady = false
    @ObservationIgnored private var restoredBanner = false

    init(track: MusicTrack, videoID: String, player: MusicPlayer, start: MusicLyricsDraft, drafts: MusicLyricsDraftStore = MusicLyricsDraftStore(directory: MusicLyricsDraftStore.defaultDirectory()),
         client: MusicLyricsSubmissionClient = MusicLyricsSubmissionClient()) {
        self.track = track; self.videoID = videoID; self.player = player; self.drafts = drafts; self.client = client
        if let saved = drafts.load(videoID: videoID) { draft = saved; banner = "Picked up where you left off." } else { draft = start }
        selectedID = draft.lines.first?.id
        tapOffsetMs = UserDefaults.standard.double(forKey: Self.offsetKey)
        let t = UserDefaults.standard.double(forKey: Self.tempoKey)
        tempo = t > 0 ? MusicLyricsTapMath.clampTempo(t) : MusicLyricsTapMath.defaultTempo
    }

    // MARK: lifecycle

    /// Opening slows the song to the editor speed and starts the loop watcher.
    func open() {
        if userTempo == nil { userTempo = player.tempo }
        applyTempo()
        startLoopWatcher()
    }

    /// Closing puts the person's speed back, never touching the queue or repeat.
    func close() {
        loopTask?.cancel(); loopTask = nil
        saveNow()
        if let t = userTempo { try? player.setTempo(t); userTempo = nil }
    }

    private func applyTempo() {
        guard userTempo != nil else { return }
        let target = previewing ? 1.0 : tempo
        if abs(player.tempo - target) > 0.001 { try? player.setTempo(target) }
        UserDefaults.standard.set(tempo, forKey: Self.tempoKey)
    }

    // MARK: drafts

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = draft, store = drafts
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do { try store.save(snapshot) } catch { notice = "This device refused to store the draft." }
        }
        let ready = draft.allDone
        if ready && !wasReady { celebrated = true }
        wasReady = ready
    }

    func saveNow() { saveTask?.cancel(); try? drafts.save(draft) }

    func discardDraft(restoringTo start: MusicLyricsDraft) {
        drafts.delete(videoID: videoID)
        draft = start; banner = nil; pass = nil; selectedID = start.lines.first?.id
    }

    // MARK: selection and passes

    var selectedIndex: Int? { selectedID.flatMap { draft.index(of: $0) } }
    var selectedLine: MusicLyricsDraftLine? { selectedIndex.map { draft.lines[$0] } }

    func select(_ id: Int) {
        selectedID = id; pass = nil
        if let l = selectedLine, l.hasBackground, l.indices(background: false).allSatisfy({ l.words[$0].timed }), !l.indices(background: true).allSatisfy({ l.words[$0].timed }) { backgroundPass = true } else { backgroundPass = false }
        seekToLoopStart()
    }

    func move(by d: Int) {
        guard let i = selectedIndex, draft.lines.indices.contains(i + d) else { return }
        select(draft.lines[i + d].id)
    }

    func selectNextToDo() { if let n = draft.nextToDo { select(draft.lines[n].id) } }

    func restartLine() { pass = nil; seekToLoopStart() }

    /// The voice still owed: lead first until timed, then background, then lead again.
    var voiceOwed: (lead: Bool, background: Bool) {
        guard let l = selectedLine else { return (false, false) }
        return (l.indices(background: false).contains { !l.words[$0].timed }, l.indices(background: true).contains { !l.words[$0].timed })
    }

    // MARK: tapping

    /// A tap (key F or J, or the Tap button). Uses the player sample, not the drawn playhead, so output latency and read delay cancel out.
    func tap(eventWall: Double = Date().timeIntervalSinceReferenceDate) {
        guard step == .timing, let line = selectedLine else { return }
        refreshSample()
        guard let ms = MusicLyricsTapMath.songTime(samplePositionSeconds: sample.position, sampleWall: sample.wall, tapWall: min(eventWall, Date().timeIntervalSinceReferenceDate),
                                                    speed: sample.speed, offsetMs: tapOffsetMs, paused: sample.paused) else { return }
        if line.isBreak || (line.needsStart && pass == nil) {
            draft.setLineStart(ms, line: line.id)
            if line.isBreak || line.words.isEmpty { advance() }
            return
        }
        if pass == nil { pass = draft.startPass(line: line.id, background: backgroundPass) }
        guard var p = pass else { return }
        MusicLyricsDraft.register(tap: ms, in: &p)
        pass = p
        if p.isComplete { finishPass() }
    }

    /// Ends the pass: all words need a tap or nothing changes.
    func finishPass() {
        guard let p = pass, let i = draft.index(of: p.lineID) else { pass = nil; return }
        let next = i + 1 < draft.lines.count ? draft.lines[i + 1].startMs : nil
        let hint = next.map { min($0, (p.taps.last ?? 0) + 2500) }
        if draft.commit(p, lineEndHintMs: hint) {
            pass = nil
            let owed = voiceOwed
            if owed.background { backgroundPass = true } else if owed.lead && backgroundPass { backgroundPass = false } else { advance() }
        } else { pass = nil }
    }

    private func advance() {
        if let i = selectedIndex, draft.lines.indices.contains(i + 1) { select(draft.lines[i + 1].id) }
    }

    // MARK: player sampling and the loop

    private func refreshSample() {
        sample = (player.position, Date().timeIntervalSinceReferenceDate, player.tempo, !player.isPlaying)
    }

    var loopRange: ClosedRange<Int64>? {
        guard loopOn, let i = selectedIndex, let start = draft.lines[i].firstStart else { return nil }
        let next = draft.lines.dropFirst(i + 1).compactMap(\.startMs).first
        return MusicLyricsTapMath.loopRange(start: start, end: draft.lines[i].lastEnd, nextStart: next, songLengthMs: Int64(player.duration * 1000))
    }

    func seekToLoopStart() {
        guard let r = loopRange else { return }
        player.seek(to: Double(r.lowerBound) / 1000)
    }

    private func startLoopWatcher() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            var ignoreUntil = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshSample()
                var wait = 0.25
                if self.step == .timing, !self.previewing, self.player.isPlaying, let r = self.loopRange, Date() >= ignoreUntil {
                    let posMs = Int64(self.player.position * 1000)
                    if posMs >= r.upperBound || posMs < r.lowerBound - 500 {
                        self.player.seek(to: Double(r.lowerBound) / 1000)
                        ignoreUntil = Date().addingTimeInterval(0.4)
                    } else {
                        wait = min(0.25, max(0.01, Double(r.upperBound - posMs) / 1000 / max(0.1, self.player.tempo)))
                    }
                } else if !self.player.isPlaying { wait = 0.5 }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: preview

    /// The draft as lyrics, lines not yet timed left out, for the real lyrics view.
    var previewLyrics: MusicLyrics {
        let timed = draft.buildLines().filter { $0.words?.isEmpty == false || $0.text.isEmpty }
        return MusicLyrics(synced: timed, sourceName: "Your draft", providerID: MusicLyricsSources.localOwn)
    }

    // MARK: sending

    var readiness: MusicLyricsSubmissionBody.Readiness { draft.readiness }

    func submit(baseRevisionOverride: Int?? = nil) async {
        guard case .ready = readiness else { return }
        send = .sending
        let base: Int? = baseRevisionOverride ?? draft.baseRevision
        do {
            let r = try await client.submit(filedID: videoID, lines: draft.buildLines(), title: track.title, artist: track.artistLine, album: track.album?.title,
                                            durationSeconds: track.durationMs > 0 ? Int((Double(track.durationMs) / 1000).rounded()) : nil, baseRevision: base)
            drafts.delete(videoID: videoID)
            send = .done(r)
        } catch let e as MusicLyricsSubmissionError { send = .failed(e) } catch { send = .failed(.unavailable) }
    }

    /// After a "stale" answer: send on top of whatever is live now.
    func sendMineOnTopOfLive() async {
        send = .sending
        let live = try? await client.state(videoID: videoID)
        await submit(baseRevisionOverride: .some(live?.revision))
    }

    func loadRejection() async {
        guard let s = try? await client.state(videoID: videoID), let reason = s.rejectedReason, let rev = s.rejectedRevision else { return }
        rejection = (reason, rev)
    }

    static let privacyLine = "Sending publishes these lyrics, with the song's video id, title, artist, album and length, to the community lyrics service for everyone to see. No name or email is attached. The first send makes an anonymous account on this device; its key stays in the Keychain. Nothing is sent until you press Submit."
}
