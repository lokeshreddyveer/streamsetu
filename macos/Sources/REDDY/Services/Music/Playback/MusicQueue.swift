import Foundation

enum MusicRepeat: String, Codable, Sendable, CaseIterable { case off, all, one }

/// The play queue as pure value logic: rows, the playing pointer, shuffle, repeat and where added tracks land. No audio and no I/O,
/// so every rule can be tested alone.
///
/// The queue is one flat list in play order. Rows before the pointer are what was already played, the row at the pointer is playing,
/// rows after it are upcoming. Each row has its own id, so the same song can sit in the queue twice and moving or removing one copy
/// never confuses the other.
///
/// Markers: `queued` is a "Play next" add, `queuedEnd` an "Add to queue" add, `queuedFrom` names the album or playlist an add came
/// from (so a whole added album can be shuffled as one run), `auto` marks rows endless playback appended.
struct MusicQueue: Sendable {
    struct Entry: Hashable, Identifiable, Sendable {
        var id = UUID()
        var track: MusicTrack
        /// True for tracks added by endless playback rather than by the person.
        var auto = false
        /// Added with "Play next".
        var queued = false
        /// Added with "Add to queue".
        var queuedEnd = false
        /// The album or playlist title an add came from.
        var queuedFrom: String? = nil
        /// Who added it in a listening room.
        var queuedBy: String? = nil
        /// A recommended song Smart Shuffle placed between the person's own songs.
        var suggested = false
        /// The short line saying why an autoplay or suggested row is here.
        var reason: String? = nil

        var isManual: Bool { queued || queuedEnd }
    }

    /// One saved row. Decoding tolerates every marker missing.
    struct Row: Codable, Sendable, Equatable {
        var id: UUID
        var track: MusicTrack
        var auto: Bool
        var queued: Bool
        var queuedEnd: Bool
        var queuedFrom: String?
        var queuedBy: String?
        var suggested: Bool
        var reason: String?

        init(_ e: Entry) {
            id = e.id; track = e.track; auto = e.auto; queued = e.queued; queuedEnd = e.queuedEnd
            queuedFrom = e.queuedFrom; queuedBy = e.queuedBy; suggested = e.suggested; reason = e.reason
        }

        var entry: Entry {
            Entry(id: id, track: track, auto: auto, queued: queued, queuedEnd: queuedEnd, queuedFrom: queuedFrom, queuedBy: queuedBy,
                  suggested: suggested, reason: reason)
        }

        private enum CodingKeys: String, CodingKey { case id, track, auto, queued, queuedEnd, queuedFrom, queuedBy, suggested, reason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            track = try c.decode(MusicTrack.self, forKey: .track)
            auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
            queued = try c.decodeIfPresent(Bool.self, forKey: .queued) ?? false
            queuedEnd = try c.decodeIfPresent(Bool.self, forKey: .queuedEnd) ?? false
            queuedFrom = try c.decodeIfPresent(String.self, forKey: .queuedFrom)
            queuedBy = try c.decodeIfPresent(String.self, forKey: .queuedBy)
            suggested = try c.decodeIfPresent(Bool.self, forKey: .suggested) ?? false
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    /// What is saved between launches. Every field after `position` is optional so a queue saved by an older build still loads: such a
    /// file carries only `tracks` and `autoIndices`.
    struct Snapshot: Codable, Sendable {
        var tracks: [MusicTrack]
        var index: Int?
        var shuffle: Bool
        var repeatMode: MusicRepeat
        var position: TimeInterval
        var autoIndices: [Int]? = nil
        var rows: [Row]? = nil
        /// The order before shuffle was switched on. Present exactly while shuffle is on, so un-shuffling still works after a restart.
        var preShuffle: [Row]? = nil
        var radioSeed: String? = nil
        var sourceName: String? = nil
        var sourceID: String? = nil
        var isRadio: Bool? = nil
    }

    /// The small record written on every save. It is trusted only when `fp` matches the rows it is read against.
    struct IndexRecord: Codable, Sendable, Equatable {
        var current: Int?
        var repeatMode: MusicRepeat
        var fp: String
        var position: TimeInterval
    }

    /// The queue that a click replaced. One level only.
    struct PreviousContext: Sendable {
        var rows: [Entry]
        var currentID: Entry.ID?
        var preShuffle: [Entry]?
        var radioSeed: String?
        var sourceName: String?
        var sourceID: String?
        var isRadio: Bool
        var position: TimeInterval
        var title: String
    }

    /// Per-call switches that live in the settings.
    struct Options: Sendable {
        var preventDuplicates = false
        var shuffleWholeQueue = false
        init(preventDuplicates: Bool = false, shuffleWholeQueue: Bool = false) {
            self.preventDuplicates = preventDuplicates; self.shuffleWholeQueue = shuffleWholeQueue
        }
    }

    struct AddResult: Equatable, Sendable {
        /// The queue was empty, so row 0 should start playing.
        var startedEmpty = false
        var added = 0
    }

    typealias Shuffler = @Sendable (inout [Entry]) -> Void
    static let systemShuffle: Shuffler = { $0.shuffle() }
    static let systemPick: @Sendable (Int) -> Int = { Int.random(in: 0..<max(1, $0)) }

    /// Played rows kept behind the pointer when endless playback appends.
    static let historyLimit = 200
    /// Most rows one endless playback hop may add.
    static let autoplayHopCap = 20
    /// Endless playback runs when this many rows or fewer of the person's own context remain after the pointer...
    static let autoplayTrigger = MusicAutoplayEngine.contextTrigger
    /// ...and fewer than this many autoplay rows are waiting.
    static let autoplayLowWater = MusicAutoplayEngine.lowWater

    private(set) var entries: [Entry] = [] { didSet { editStamp &+= 1 } }
    private(set) var currentID: Entry.ID?
    private(set) var preShuffle: [Entry]?
    var repeatMode: MusicRepeat = .off
    private(set) var radioSeed: String?
    private(set) var sourceName: String?
    private(set) var sourceID: String?
    private(set) var isRadio = false
    /// Changes only when a different queue replaces this one, never on a skip.
    private(set) var epoch = 0
    private(set) var previousContext: PreviousContext?
    /// Under shuffle with repeat-all, makes the next lap's order from the finished lap. Set by the player from the shuffle engine.
    var lapShuffler: (@Sendable ([Entry]) -> [Entry])?
    private var pendingLap: [Entry]?
    /// Bumped on every change to `entries`; a pending lap is valid only for the stamp it was made at (one integer compare, no set building).
    private var editStamp = 0
    private var pendingStamp = -1
    /// Used when shuffle and repeat-all are on but no lap shuffler was installed (for example right after a restart): the same engine, a fresh seed.
    private static let fallbackLap: @Sendable ([Entry]) -> [Entry] = { rows in
        MusicShuffleEngine.lap(rows, mode: .smart, seed: UInt64.random(in: .min ... .max))
    }

    var shuffle: Bool { preShuffle != nil }

    init() {}

    init(snapshot: Snapshot) {
        if let rows = snapshot.rows {
            entries = rows.map(\.entry)
            preShuffle = snapshot.preShuffle?.map(\.entry)
        } else {
            let autos = Set(snapshot.autoIndices ?? [])
            entries = snapshot.tracks.enumerated().map { Entry(track: $1, auto: autos.contains($0)) }
            // An older file only knew that shuffle was on; the best reversible order is the one it was saved in.
            preShuffle = snapshot.shuffle ? entries : nil
        }
        if let i = snapshot.index, entries.indices.contains(i) { currentID = entries[i].id } else { currentID = entries.first?.id }
        repeatMode = snapshot.repeatMode
        radioSeed = snapshot.radioSeed; sourceName = snapshot.sourceName; sourceID = snapshot.sourceID
        isRadio = snapshot.isRadio ?? false
    }

    func snapshot(position: TimeInterval) -> Snapshot {
        Snapshot(tracks: [], index: index, shuffle: shuffle, repeatMode: repeatMode, position: position,
                 autoIndices: nil, rows: entries.map(Row.init), preShuffle: preShuffle?.map(Row.init),
                 radioSeed: radioSeed, sourceName: sourceName, sourceID: sourceID, isRadio: isRadio)
    }

    // MARK: reading

    var tracks: [MusicTrack] { entries.map(\.track) }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var index: Int? { currentID.flatMap { id in entries.firstIndex { $0.id == id } } }
    var current: Entry? { index.map { entries[$0] } }
    var autoCount: Int { entries.filter(\.auto).count }
    /// Autoplay rows after the playing one.
    var upcomingAutoCount: Int { index.map { c in entries[(c + 1)...].filter(\.auto).count } ?? 0 }
    /// Rows after the playing one that the person or the original context put there (neither autoplay nor suggestions).
    var contextRemaining: Int { index.map { c in entries[(c + 1)...].filter { !$0.auto && !$0.suggested }.count } ?? 0 }
    /// Smart Shuffle suggestions after the playing row.
    var upcomingSuggestedCount: Int { index.map { c in entries[(c + 1)...].filter(\.suggested).count } ?? 0 }
    /// The person's own songs waiting in the context (what Smart Shuffle suggestions are spread between).
    var upcomingOwnCount: Int { contextRemaining }
    /// The own songs after the last suggestion already placed (all upcoming own songs when there is none): the only room a new suggestion has.
    var ownAfterLastSuggestion: Int {
        guard let c = index else { return 0 }
        let part = Array(entries[(c + 1)...].prefix { !$0.auto })
        guard let last = part.lastIndex(where: { $0.suggested }) else { return part.count }
        return part.count - 1 - last
    }

    /// Rows after the playing one.
    var rowsRemaining: Int { index.map { entries.count - 1 - $0 } ?? 0 }

    /// True when a "next" would play something (used to enable the Next key).
    var hasNext: Bool {
        guard let i = index else { return false }
        return repeatMode != .off || i < entries.count - 1
    }

    /// Upcoming rows the person added by hand. "Clear queue" is offered only when there are some.
    var hasManualUpcoming: Bool {
        guard let c = index else { return false }
        return entries[(c + 1)...].contains { $0.isManual }
    }

    /// The "Back to <title>" label: shown only while the pointer is on row 0 and a replaced queue is kept.
    var backTitle: String? { index == 0 ? previousContext?.title : nil }

    /// Index of the first upcoming autoplay row, if any. The panel draws its divider there.
    var firstAutoplayIndex: Int? {
        guard let c = index else { return nil }
        return entries[(c + 1)...].firstIndex { $0.auto }
    }

    // MARK: building

    /// Replaces the queue. Upcoming manual adds survive the switch (unless the new list already holds that song): "Play next" rows sit
    /// right after the new playing row and "Add to queue" rows sit behind the new list. The queue that was replaced is kept one level
    /// deep so the person can go back to it.
    mutating func replace(with tracks: [MusicTrack], startAt: Int, sourceName: String? = nil, sourceID: String? = nil,
                          radioSeed: String? = nil, isRadio: Bool = false, leavingPosition: TimeInterval = 0, remember: Bool = true) {
        let incoming = Set(tracks.map(\.uid))
        var carriedNext: [Entry] = [], carriedEnd: [Entry] = []
        if let c = index {
            for e in entries[(c + 1)...] where e.isManual && !incoming.contains(e.track.uid) {
                if e.queued { carriedNext.append(e) } else { carriedEnd.append(e) }
            }
        }
        if remember, let cur = current {
            previousContext = PreviousContext(rows: entries, currentID: currentID, preShuffle: preShuffle, radioSeed: self.radioSeed,
                                              sourceName: self.sourceName, sourceID: self.sourceID, isRadio: self.isRadio,
                                              position: leavingPosition, title: self.sourceName ?? cur.track.title)
        } else if !remember { previousContext = nil }
        var rows = tracks.map { Entry(track: $0) }
        if rows.isEmpty {
            rows = carriedNext + carriedEnd
            currentID = rows.first?.id
        } else {
            let start = min(max(0, startAt), rows.count - 1)
            currentID = rows[start].id
            rows.insert(contentsOf: carriedNext, at: start + 1)
            rows.append(contentsOf: carriedEnd)
        }
        entries = rows
        preShuffle = nil
        self.sourceName = sourceName; self.sourceID = sourceID; self.radioSeed = radioSeed; self.isRadio = isRadio
        epoch += 1
    }

    /// Names where the queue came from and what continues it.
    mutating func setSource(name: String?, id: String? = nil, radioSeed: String? = nil, isRadio: Bool = false) {
        sourceName = name; sourceID = id; self.radioSeed = radioSeed; self.isRadio = isRadio
    }

    /// Puts the queue that a click replaced back. Returns the position to resume at, or nil when there is nothing to restore.
    @discardableResult
    mutating func restorePreviousContext() -> TimeInterval? {
        guard let p = previousContext else { return nil }
        entries = p.rows; currentID = p.currentID; preShuffle = p.preShuffle
        radioSeed = p.radioSeed; sourceName = p.sourceName; sourceID = p.sourceID; isRadio = p.isRadio
        previousContext = nil
        epoch += 1
        return p.position
    }

    // MARK: adding

    /// "Play next": right after the playing row and behind the Play-next rows already waiting (first in, first out).
    @discardableResult
    mutating func playNext(_ tracks: [MusicTrack], from: String? = nil, by: String? = nil, options: Options = Options(),
                           pick: (Int) -> Int = MusicQueue.systemPick, shuffler: Shuffler = MusicQueue.systemShuffle) -> AddResult {
        add(tracks, end: false, from: from, by: by, options: options, pick: pick, shuffler: shuffler)
    }

    /// "Add to queue": behind the playing album or playlist and ahead of endless-playback rows. In a radio queue it goes behind the
    /// manual adds and ahead of the radio.
    @discardableResult
    mutating func addToQueue(_ tracks: [MusicTrack], from: String? = nil, by: String? = nil, options: Options = Options(),
                             pick: (Int) -> Int = MusicQueue.systemPick, shuffler: Shuffler = MusicQueue.systemShuffle) -> AddResult {
        add(tracks, end: true, from: from, by: by, options: options, pick: pick, shuffler: shuffler)
    }

    /// Rows the playing list is still handing over (a long chart being confirmed, the rest of the row that was pressed). They are part of that list: no "Queued" mark,
    /// "Clear queue" leaves them and they never follow the next list. They go behind the list and ahead of the autoplay rows; with a `shuffler` the batch is shuffled and the
    /// shuffle snapshot keeps the order given. An emptied queue takes nothing. Returns how many were added.
    @discardableResult
    mutating func extendContext(_ tracks: [MusicTrack], shuffler: Shuffler? = nil) -> Int {
        guard !tracks.isEmpty, let c = index else { return 0 }
        let original = tracks.map { Entry(track: $0) }
        var rows = original
        if shuffle, let shuffler, rows.count > 1 { shuffler(&rows) }
        entries.insert(contentsOf: rows, at: entries[(c + 1)...].firstIndex { $0.auto } ?? entries.count)
        if let snap = preShuffle {
            let pc = snap.firstIndex { $0.id == currentID } ?? -1
            preShuffle?.insert(contentsOf: original, at: snap[(pc + 1)...].firstIndex { $0.auto } ?? snap.count)
        }
        return rows.count
    }

    /// Autoplay rows are the tail of the queue. A queue saved by an older build could hold a row the person had moved behind them ("Move to Bottom"): such rows go back in
    /// front, in their own order. Returns true when anything moved.
    @discardableResult
    mutating func repairAutoplayTail() -> Bool {
        guard let c = index, c + 1 < entries.count else { return false }
        let upcoming = Array(entries[(c + 1)...])
        guard let a = upcoming.firstIndex(where: { $0.auto }), upcoming[a...].contains(where: { !$0.auto }) else { return false }
        entries = Array(entries[...c]) + upcoming.filter { !$0.auto } + upcoming.filter { $0.auto }
        return true
    }

    /// Appends plain or auto rows at the very end, with no marker rules.
    mutating func append(_ tracks: [MusicTrack], auto: Bool = false) {
        let added = tracks.map { Entry(track: $0, auto: auto) }
        guard !added.isEmpty else { return }
        entries += added
        preShuffle?.append(contentsOf: added)
        if currentID == nil { currentID = entries.first?.id }
    }

    private mutating func add(_ tracks: [MusicTrack], end: Bool, from: String?, by: String?, options: Options,
                              pick: (Int) -> Int, shuffler: Shuffler) -> AddResult {
        guard !tracks.isEmpty else { return AddResult() }
        let uids = Set(tracks.map(\.uid))
        // Tracks already waiting in the manual block are moved, never doubled; with prevent-duplicates every other copy goes.
        var gone = Set<Entry.ID>()
        let c0 = index
        for (i, e) in entries.enumerated() where uids.contains(e.track.uid) && e.id != currentID {
            let upcoming = c0.map { i > $0 } ?? true
            if options.preventDuplicates || (upcoming && e.isManual) { gone.insert(e.id) }
        }
        if !gone.isEmpty {
            entries.removeAll { gone.contains($0.id) }
            preShuffle?.removeAll { gone.contains($0.id) }
        }
        var rows = tracks.map { Entry(track: $0, queued: !end, queuedEnd: end, queuedFrom: from, queuedBy: by) }
        if entries.isEmpty {
            rows[0].queued = false; rows[0].queuedEnd = false
            entries = rows
            currentID = rows[0].id
            // Shuffle stays on across an emptied queue: the unshuffled snapshot is what says so (`shuffle` reads it), so keep one.
            preShuffle = shuffle ? rows : nil
            return AddResult(startedEmpty: true, added: rows.count)
        }
        let original = rows   // the order the source gave: turning shuffle off must hand it back, not the shuffled one
        if shuffle, from != nil, rows.count > 1 { shuffler(&rows) }
        guard let c = index else { return AddResult() }
        var at: Int
        if end {
            at = isRadio ? c + 1 + Self.leadingManualRun(entries, after: c) : (firstAutoplayIndex ?? entries.count)
        } else {
            at = c + 1 + Self.leadingQueuedRun(entries, after: c)
        }
        if end, shuffle, options.shuffleWholeQueue {
            let lo = c + 1 + Self.leadingQueuedRun(entries, after: c)
            let hi = firstAutoplayIndex ?? entries.count
            if hi > lo { at = lo + min(max(0, pick(hi - lo + 1)), hi - lo) }
        }
        entries.insert(contentsOf: rows, at: min(at, entries.count))
        if var snap = preShuffle {
            let pc = snap.firstIndex { $0.id == currentID } ?? -1
            var sat: Int
            if end { sat = snap[(pc + 1)...].firstIndex { $0.auto } ?? snap.count }
            else { sat = pc + 1 + Self.leadingQueuedRun(snap, after: pc) }
            sat = min(max(0, sat), snap.count)
            snap.insert(contentsOf: original, at: sat)
            preShuffle = snap
        }
        return AddResult(startedEmpty: false, added: rows.count)
    }

    private static func leadingQueuedRun(_ rows: [Entry], after c: Int) -> Int {
        var n = 0
        var i = c + 1
        while i < rows.count, rows[i].queued { n += 1; i += 1 }
        return n
    }

    private static func leadingManualRun(_ rows: [Entry], after c: Int) -> Int {
        var n = 0
        var i = c + 1
        while i < rows.count, rows[i].isManual { n += 1; i += 1 }
        return n
    }

    /// Removes every upcoming row the person added by hand. Played rows, the playing row and the playlist context stay.
    @discardableResult
    mutating func clearManual() -> Int {
        guard let c = index else { return 0 }
        let gone = Set(entries[(c + 1)...].filter(\.isManual).map(\.id))
        guard !gone.isEmpty else { return 0 }
        entries.removeAll { gone.contains($0.id) }
        preShuffle?.removeAll { gone.contains($0.id) }
        return gone.count
    }

    // MARK: endless playback rows

    /// Whether endless playback should fetch now: switched on, not a guest, no fetch running, repeat off, two rows or fewer left.
    func wantsAutoplay(enabled: Bool, isGuest: Bool, hydrating: Bool) -> Bool {
        enabled && !isGuest && !hydrating && repeatMode == .off && index != nil && contextRemaining <= Self.autoplayTrigger
            && upcomingAutoCount < Self.autoplayLowWater
    }

    /// Adds what endless playback found: drops anything already queued or repeated in the batch, puts rows not heard in the last 30 days
    /// first (the rest least recently heard first), keeps at most `cap`, and marks each as an autoplay row. Returns how many were added.
    @discardableResult
    mutating func mergeAutoplay(_ tracks: [MusicTrack], lastHeard: [String: Date] = [:], now: Date = Date(),
                                cap: Int = MusicQueue.autoplayHopCap) -> Int {
        var seen = Set(entries.map(\.track.uid))
        var fresh: [MusicTrack] = []
        for t in tracks where seen.insert(t.uid).inserted { fresh.append(t) }
        let ordered = MusicAutoplayOrder.freshFirst(fresh, lastHeard: lastHeard, now: now)
        let rows = ordered.prefix(max(0, cap)).map { Entry(track: $0, auto: true) }
        guard !rows.isEmpty else { return 0 }
        entries.append(contentsOf: rows)
        preShuffle?.append(contentsOf: rows)
        if currentID == nil { currentID = entries.first?.id }
        return rows.count
    }

    /// Adds what the autoplay engine chose. Each row keeps its reason for the queue to show. Returns how many were added.
    @discardableResult
    mutating func mergeAutoplayPicks(_ picks: [MusicAutoplayPick], cap: Int = MusicQueue.autoplayHopCap) -> Int {
        var seen = Set(entries.map(\.track.uid))
        let rows = picks.filter { seen.insert($0.track.uid).inserted }.prefix(max(0, cap)).map { Entry(track: $0.track, auto: true, reason: $0.text) }
        guard !rows.isEmpty else { return 0 }
        entries.append(contentsOf: rows)
        preShuffle?.append(contentsOf: rows)
        if currentID == nil { currentID = entries.first?.id }
        return rows.count
    }

    /// "Keep": an upcoming autoplay row becomes an ordinary row of the context, placed just ahead of the remaining autoplay rows.
    @discardableResult
    mutating func keepAuto(id: Entry.ID) -> Bool {
        guard let c = index, let i = entries.firstIndex(where: { $0.id == id }), i > c, entries[i].auto else { return false }
        var e = entries.remove(at: i)
        e.auto = false; e.reason = nil
        let at = entries[(c + 1)...].firstIndex { $0.auto } ?? entries.count
        entries.insert(e, at: at)
        if let k = preShuffle?.firstIndex(where: { $0.id == id }) { preShuffle?[k].auto = false; preShuffle?[k].reason = nil }
        return true
    }

    /// "Keep" on a Smart Shuffle suggestion: it becomes one of the person's own songs and stays through un-shuffle.
    @discardableResult
    mutating func keepSuggested(id: Entry.ID) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].suggested else { return false }
        entries[i].suggested = false; entries[i].reason = nil
        let kept = entries[i]
        if preShuffle != nil, !(preShuffle?.contains { $0.id == id } ?? false) {
            let at = preShuffle?.firstIndex { $0.auto } ?? preShuffle?.count ?? 0
            preShuffle?.insert(kept, at: at)
        }
        return true
    }

    /// Takes every upcoming suggestion out (switching Smart Shuffle off, or before a reshuffle). The playing row stays.
    @discardableResult
    mutating func removeSuggestedRows() -> Int {
        let gone = Set(entries.filter { $0.suggested && $0.id != currentID }.map(\.id))
        guard !gone.isEmpty else { return 0 }
        entries.removeAll { gone.contains($0.id) }
        return gone.count
    }

    /// Puts recommended songs between the person's own upcoming songs, after the last suggestion already there, one after every N own
    /// songs. Suggestions are not part of the shuffle snapshot, so un-shuffling drops them. Returns how many were placed.
    @discardableResult
    mutating func insertSuggestions(_ picks: [MusicAutoplayPick], every: ClosedRange<Int> = MusicSmartSuggest.every, seed: UInt64) -> Int {
        guard let c = index else { return 0 }
        var seen = Set(entries.map(\.track.uid))
        let rows = picks.filter { seen.insert($0.track.uid).inserted }.map { Entry(track: $0.track, suggested: true, reason: $0.text) }
        guard !rows.isEmpty else { return 0 }
        let upcoming = Array(entries[(c + 1)...])
        let autoStart = upcoming.firstIndex { $0.auto } ?? upcoming.count
        let ownPart = Array(upcoming[..<autoStart]), tail = Array(upcoming[autoStart...])
        let lastS = ownPart.lastIndex { $0.suggested }
        let head = lastS.map { Array(ownPart[...$0]) } ?? []
        let rest = lastS.map { Array(ownPart[($0 + 1)...]) } ?? ownPart
        var rng = MusicSeededRNG(seed: seed)
        let merged = head + MusicSmartSuggest.interleave(own: rest, suggestions: rows, every: every, using: &rng)
        entries = Array(entries[...c]) + merged + tail
        return merged.count - ownPart.count
    }

    /// Orders the upcoming rows again with a new shuffler, keeping the shuffle snapshot (so un-shuffle still restores the original order)
    /// and everything played. Suggestions go; the caller asks for new ones.
    mutating func reshuffleUpcoming(wholeQueue: Bool = false, shuffler: Shuffler) {
        guard let snap = preShuffle else { return }
        removeSuggestedRows()
        shuffleOn(wholeQueue: wholeQueue, fresh: false, shuffler: shuffler)
        preShuffle = snap
        pendingLap = nil
    }

    /// Drops played rows more than `limit` behind the pointer, from the shuffle snapshot too, so neither list grows without bound.
    /// Returns how many went.
    @discardableResult
    mutating func trimHistory(limit: Int = MusicQueue.historyLimit) -> Int {
        guard let c = index, c > limit else { return 0 }
        let drop = c - limit
        if preShuffle != nil {
            let gone = Set(entries.prefix(drop).map(\.id))
            preShuffle?.removeAll { gone.contains($0.id) }
        }
        entries.removeFirst(drop)
        return drop
    }

    /// Removes every auto-added row except the one playing, which becomes an ordinary row. Rows the person moved or placed already lost
    /// their flag, so they stay.
    mutating func clearAuto() {
        if let i = index { entries[i].auto = false }
        let gone = Set(entries.filter(\.auto).map(\.id))
        guard !gone.isEmpty else { return }
        entries.removeAll { gone.contains($0.id) }
        preShuffle?.removeAll { gone.contains($0.id) }
    }

    // MARK: shuffle

    /// Turns shuffle on (snapshot the order, shuffle only what is upcoming) or off (restore the snapshot minus what already played).
    /// `fresh` is for a new list that has just started at a chosen opener: the opener plays first and EVERY other row, including those
    /// before it in the list, is still to come.
    mutating func setShuffle(_ on: Bool, wholeQueue: Bool = false, fresh: Bool = false, shuffler: Shuffler = MusicQueue.systemShuffle) {
        guard on != shuffle else { return }
        if on { shuffleOn(wholeQueue: wholeQueue, fresh: fresh, shuffler: shuffler) } else { shuffleOff() }
    }

    private mutating func shuffleOn(wholeQueue: Bool, fresh: Bool, shuffler: Shuffler) {
        preShuffle = entries
        let c = index ?? -1
        let head: [Entry]
        var earlier: [Entry] = []
        if fresh, c >= 0 {
            head = [entries[c]]
            earlier = Array(entries.prefix(c))
        } else {
            head = Array(entries.prefix(c + 1))
        }
        let upcoming = Array(entries.dropFirst(c + 1))
        // The leading run of Play-next rows stays at the front in order; a run from one added album is shuffled inside itself.
        var pinned: [Entry] = []
        var i = 0
        while i < upcoming.count, upcoming[i].queued {
            var j = i + 1
            if let from = upcoming[i].queuedFrom {
                while j < upcoming.count, upcoming[j].queued, upcoming[j].queuedFrom == from { j += 1 }
                var run = Array(upcoming[i..<j]); shuffler(&run); pinned += run
            } else { pinned.append(upcoming[i]) }
            i = j
        }
        let rest = Array(upcoming[i...]) + earlier
        var context = rest.filter { !$0.auto && (wholeQueue || !$0.queuedEnd) }
        var adds = wholeQueue ? [] : rest.filter { !$0.auto && $0.queuedEnd }
        var autos = rest.filter(\.auto)
        shuffler(&context); shuffler(&adds); shuffler(&autos)
        entries = head + pinned + context + adds + autos
    }

    /// Restores the original order: what was played stays behind as history in the order it was played, the playing row stays, and every
    /// alive row of the snapshot that has not been played comes after it in its original relative order (Play next rows first).
    private mutating func shuffleOff() {
        guard let snap = preShuffle else { return }
        preShuffle = nil
        guard let c = index else { return }
        let history = Array(entries[..<c])
        let playing = entries[c]
        let skip = Set(history.map(\.id)).union([playing.id])
        let alive = Set(entries.map(\.id))
        let leftover = snap.filter { alive.contains($0.id) && !skip.contains($0.id) }
        // Manual adds go back: Play next right after the playing row, then the rest of the playlist, then Add to queue, then endless rows.
        let next = leftover.filter { $0.queued }
        let adds = leftover.filter { !$0.queued && $0.queuedEnd }
        let autos = leftover.filter { !$0.queued && !$0.queuedEnd && $0.auto }
        let context = leftover.filter { !$0.queued && !$0.queuedEnd && !$0.auto }
        entries = history + [playing] + next + context + adds + autos
    }

    // MARK: removing, moving

    /// Removes the row at `i` (from the shuffle snapshot too). Returns true when it was the playing one: the caller must start what is
    /// now current, or stop.
    @discardableResult
    mutating func remove(at i: Int) -> Bool {
        guard entries.indices.contains(i) else { return false }
        let gone = entries[i]
        let wasCurrent = gone.id == currentID
        if wasCurrent {
            currentID = i + 1 < entries.count ? entries[i + 1].id : (i > 0 ? entries[i - 1].id : nil)
        }
        entries.remove(at: i)
        preShuffle?.removeAll { $0.id == gone.id }
        return wasCurrent
    }

    /// Moves an upcoming row. Both positions must be after the playing row and inside the list; `to` is the row's final index. The autoplay rows stay the tail:
    /// a row of the list asked to go behind them stops just in front. An autoplay row the person brings among their own rows is theirs from then on (its flag is
    /// cleared); one moved inside the autoplay rows stays one. Returns false when nothing changed.
    @discardableResult
    mutating func moveUpcoming(from: Int, to: Int) -> Bool {
        guard let c = index, from > c, to > c, entries.indices.contains(from), entries.indices.contains(to), from != to else { return false }
        let before = entries[from]
        var e = before
        var rest = entries
        rest.remove(at: from)
        let firstAuto = rest.indices.first { $0 > c && rest[$0].auto }
        var target = to
        if !e.auto {
            if let a = firstAuto, target > a { target = a }
        } else if firstAuto.map({ target <= $0 }) ?? true {
            e.auto = false
        }
        guard target != from || e.auto != before.auto else { return false }
        rest.insert(e, at: target)
        entries = rest
        if let k = preShuffle?.firstIndex(where: { $0.id == e.id }) { preShuffle?[k].auto = e.auto }
        return true
    }

    /// Undo of a move: the row goes back to `at` with the autoplay flag it had. No rule is applied, because the place it returns to was a valid one.
    @discardableResult
    mutating func putBack(id: Entry.ID, at: Int, auto: Bool) -> Bool {
        guard let c = index, let from = entries.firstIndex(where: { $0.id == id }), from > c else { return false }
        var e = entries.remove(at: from)
        e.auto = auto
        entries.insert(e, at: min(max(at, c + 1), entries.count))
        if let k = preShuffle?.firstIndex(where: { $0.id == id }) { preShuffle?[k].auto = auto }
        return true
    }

    /// "Move to Play Next": puts an upcoming row right after the playing one and marks it as put next by hand, so it sits with the Play next rows.
    /// Returns false when the row is not an upcoming one.
    @discardableResult
    mutating func moveToPlayNext(from: Int) -> Bool {
        guard let c = index, from > c, entries.indices.contains(from) else { return false }
        var e = entries.remove(at: from)
        e.auto = false; e.suggested = false; e.queued = true; e.queuedEnd = false
        entries.insert(e, at: c + 1)
        if let k = preShuffle?.firstIndex(where: { $0.id == e.id }) {
            preShuffle?[k].auto = false; preShuffle?[k].suggested = false; preShuffle?[k].queued = true; preShuffle?[k].queuedEnd = false
        }
        return true
    }

    /// Compatibility name for `moveUpcoming`.
    mutating func move(from: Int, to: Int) { moveUpcoming(from: from, to: to) }

    /// Indices of upcoming rows matching `match`, highest first, so removing them one by one never renumbers a later one.
    func upcomingIndices(where match: (MusicTrack) -> Bool) -> [Int] {
        guard let c = index else { return [] }
        return entries.indices.filter { $0 > c && match(entries[$0].track) }.reversed()
    }

    /// Removes every row after the playing one and keeps the played rows and the playing row. Returns how many went.
    @discardableResult
    mutating func removeUpcoming() -> Int {
        guard let c = index, c + 1 < entries.count else { return 0 }
        let gone = Set(entries[(c + 1)...].map(\.id))
        entries.removeSubrange((c + 1)...)
        preShuffle?.removeAll { gone.contains($0.id) }
        return gone.count
    }

    /// Empties the queue, or keeps only the playing track.
    mutating func clear(keepCurrent: Bool) {
        if keepCurrent, var c = current { c.queued = false; c.queuedEnd = false; entries = [c] }
        else { entries = []; currentID = nil }
        preShuffle = nil
        previousContext = nil
    }

    /// Makes the row at `i` current (a tap on a queue row).
    /// Under shuffle, rows skipped over by a forward jump are not lost for the cycle: the target moves to just after the playing row, so
    /// the skipped rows stay upcoming right behind it and Previous still returns to the row that was playing.
    mutating func jump(to i: Int) {
        guard entries.indices.contains(i) else { return }
        if shuffle, let c = index, i > c + 1 {
            let target = entries.remove(at: i)
            entries.insert(target, at: c + 1)
            currentID = target.id
        } else {
            currentID = entries[i].id
        }
        pointerMoved()
    }

    // MARK: moving through it

    /// The row an automatic end of track would play next, without moving. Nil under repeat-one (the file loops itself) and at the tail
    /// with repeat off.
    func peekNext() -> Entry? {
        guard let cur = index, repeatMode != .one else { return nil }
        if cur + 1 < entries.count { return entries[cur + 1] }
        guard repeatMode == .all else { return nil }
        return (validPendingLap() ?? entries).first
    }

    /// The next lap's order when it was made ahead and no row has changed since.
    private func validPendingLap() -> [Entry]? {
        guard let p = pendingLap, pendingStamp == editStamp else { return nil }
        return p
    }

    /// Makes the next lap ahead when the pointer is on the last row of a shuffled repeat-all queue and no valid one exists (after an edit
    /// there, a new repeat mode or a new shuffler), so the lookahead and the real advance agree. Cheap when there is nothing to do.
    mutating func refreshPendingLap() {
        guard shuffle, repeatMode != .off, let i = index, i == entries.count - 1, entries.count > 1 else { pendingLap = nil; return }
        if pendingLap != nil, pendingStamp == editStamp { return }
        let f = lapShuffler ?? Self.fallbackLap
        pendingLap = f(lapRows)
        pendingStamp = editStamp
    }

    /// The rows a new lap orders: the person's own songs. When only suggestions are left (every own row was removed) they become the list, as ordinary rows, so a lap is
    /// never empty.
    private var lapRows: [Entry] {
        let own = entries.filter { !$0.suggested }
        if !own.isEmpty { return own }
        return entries.map { var e = $0; e.suggested = false; e.reason = nil; return e }
    }

    /// Repeat-all under shuffle: the lap just finished is re-ordered (nothing from its last 20% opens the next one, no suggestions carry over).
    private mutating func startNextLap() {
        guard shuffle, repeatMode != .off, entries.count > 1 else { return }
        let f = lapShuffler ?? Self.fallbackLap
        let next = validPendingLap() ?? f(lapRows)
        // The finished lap's Play-next / Add-to-queue marks are spent: every row of the new lap is plain context.
        entries = next.map(Self.clearedMarks)
        preShuffle = preShuffle?.map(Self.clearedMarks)
        // Former suggestions that became the list also join the unshuffled order, so turning shuffle off keeps them.
        if let snap = preShuffle {
            let held = Set(snap.map(\.id))
            preShuffle?.append(contentsOf: entries.filter { !held.contains($0.id) })
        }
        pendingLap = nil
    }

    private static func clearedMarks(_ e: Entry) -> Entry {
        var c = e
        c.queued = false; c.queuedEnd = false; c.queuedFrom = nil; c.queuedBy = nil
        return c
    }

    /// Moves to the next track. `auto` is true when the track ended by itself (repeat-one then replays it); a person pressing Next always
    /// moves on, and under repeat-one that behaves as repeat-all. Returns the new current row, or nil at the end of the queue.
    @discardableResult
    mutating func advance(auto: Bool) -> Entry? {
        guard let cur = index else { return nil }
        if auto && repeatMode == .one { return entries[cur] }
        let target: Int
        if cur + 1 < entries.count { target = cur + 1 }
        else if repeatMode != .off { startNextLap(); target = 0 }
        else { return nil }
        guard entries.indices.contains(target) else { return nil }
        currentID = entries[target].id
        pointerMoved()
        return entries[target]
    }

    /// Moves to the row before the playing one. Nil at row 0 (the caller replays it, or restores the previous queue).
    @discardableResult
    mutating func retreat() -> Entry? {
        guard let cur = index, cur > 0 else { return nil }
        currentID = entries[cur - 1].id
        pointerMoved()
        return entries[cur - 1]
    }

    private mutating func pointerMoved() {
        if let i = index, i > 0 { previousContext = nil }
        // Arriving on the last row of a shuffled repeat-all queue: make the next lap now, so the lookahead can preload its first song.
        pendingLap = nil
        refreshPendingLap()
    }

    // MARK: fingerprint

    /// A stable hash of everything that decides what the saved queue file contains. It ignores titles, artists, durations and artwork on
    /// purpose, so repairing those never rewrites the large file. FNV-1a, because the standard hasher is seeded differently every launch.
    func fingerprint() -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) {
            for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            h ^= 0xff; h = h &* 0x100000001b3
        }
        mix(String(entries.count))
        for e in entries {
            mix(e.track.uid)
            mix((e.queued ? "q" : "-") + (e.queuedEnd ? "e" : "-") + (e.auto ? "a" : "-") + (e.suggested ? "g" : "-"))
            mix(e.queuedFrom ?? ""); mix(e.queuedBy ?? "")
        }
        mix(String(preShuffle?.count ?? -1))
        for e in preShuffle ?? [] { mix(e.track.uid); mix((e.queued ? "q" : "-") + (e.queuedEnd ? "e" : "-") + (e.auto ? "a" : "-")) }
        mix(shuffle ? "s1" : "s0"); mix(radioSeed ?? ""); mix(sourceName ?? ""); mix(sourceID ?? ""); mix(isRadio ? "r1" : "r0")
        return String(h, radix: 16)
    }

    func indexRecord(position: TimeInterval) -> IndexRecord {
        IndexRecord(current: index, repeatMode: repeatMode, fp: fingerprint(), position: position)
    }

    /// Applies the small record, but only when it was written for exactly these rows.
    @discardableResult
    mutating func apply(_ record: IndexRecord) -> Bool {
        guard record.fp == fingerprint() else { return false }
        if let i = record.current, entries.indices.contains(i) { currentID = entries[i].id }
        repeatMode = record.repeatMode
        return true
    }
}

// MARK: endless playback ordering

enum MusicAutoplayOrder {
    /// Window inside which a heard track counts as "recent".
    static let freshDays = 30

    /// Tracks not heard in the last 30 days keep the provider's order and come first. Heard ones follow, least recently heard first.
    static func freshFirst(_ tracks: [MusicTrack], lastHeard: [String: Date], now: Date) -> [MusicTrack] {
        let cutoff = now.addingTimeInterval(-Double(freshDays) * 86_400)
        var fresh: [MusicTrack] = [], heard: [(MusicTrack, Date)] = []
        for t in tracks {
            if let d = lastHeard[t.uid], d >= cutoff { heard.append((t, d)) } else { fresh.append(t) }
        }
        let rest = heard.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset }.map(\.element.0)
        return fresh + rest
    }
}

// MARK: drag and drop

/// The numbers behind dragging queue rows. No views: the panel only feeds in coordinates.
enum MusicQueueDrag {
    static let rowHeight: CGFloat = 56
    static let autoScrollZone: CGFloat = 96
    static let autoScrollMaxSpeed: CGFloat = 1800
    static let autoScrollStep: TimeInterval = 0.016
    static let autoScrollMaxElapsed: TimeInterval = 0.1
    static let autoScrollIdleStop: TimeInterval = 3
    static let draggedOpacity = 0.4
    static let mime = "application/x-streamsetu-queue-row"

    /// Drop position as "in front of row N": the top half of a row means that row, the bottom half the next one.
    static func dropIndex(overRow row: Int, yInRow: CGFloat, rowHeight: CGFloat = MusicQueueDrag.rowHeight) -> Int {
        yInRow < rowHeight / 2 ? row : row + 1
    }

    /// The final index for a row dragged from `from` and dropped in front of `dropAt`; nil when that changes nothing.
    static func moveTarget(from: Int, dropAt: Int) -> Int? {
        let target = dropAt > from ? dropAt - 1 : dropAt
        return target == from ? nil : target
    }

    /// Signed scroll speed in points per second for a pointer at `y` inside a box of `height`. Negative scrolls up. The speed ramps
    /// linearly from 0 at the edge of the 96-point zone to 1800 at the box edge and stays at 1800 beyond it. In a box shorter than two
    /// zones the top wins.
    static func autoScrollSpeed(pointerY y: CGFloat, boxHeight height: CGFloat) -> CGFloat {
        let zone = autoScrollZone
        if y < zone { return -autoScrollMaxSpeed * min(1, max(0, (zone - y) / zone)) }
        if y > height - zone { return autoScrollMaxSpeed * min(1, max(0, (y - (height - zone)) / zone)) }
        return 0
    }

    /// Distance to scroll for one timer step, using the real elapsed time capped at 100 ms.
    static func autoScrollDistance(speed: CGFloat, elapsed: TimeInterval) -> CGFloat {
        speed * CGFloat(min(max(0, elapsed), autoScrollMaxElapsed))
    }

    /// Whether the person may drag this row: editing is allowed and the row is after the playing one.
    static func canDrag(row: Int, playing: Int?, editingAllowed: Bool) -> Bool {
        guard editingAllowed, let p = playing else { return false }
        return row > p
    }
}

// MARK: undo support

/// What undo needs from the queue: a removed row with enough of its surroundings to put it back, and the two small edits (put rows back,
/// take rows out again) that undo and redo are made of. The history itself is `MusicQueueHistory`.
extension MusicQueue {
    struct RemovedRow: Sendable, Equatable {
        enum Place: Sendable, Equatable { case played, current, upcoming }
        var entry: Entry
        var index: Int
        /// The row that sat just before it.
        var after: Entry.ID?
        var place: Place
        /// Whether the shuffle snapshot held it, and which snapshot row sat before it.
        var inSnapshot = false
        var snapshotAfter: Entry.ID?
    }

    func removedRow(at i: Int) -> RemovedRow? {
        guard entries.indices.contains(i) else { return nil }
        let id = entries[i].id
        var snapAfter: Entry.ID?
        var inSnap = false
        if let s = preShuffle, let k = s.firstIndex(where: { $0.id == id }) { inSnap = true; snapAfter = k > 0 ? s[k - 1].id : nil }
        let place: RemovedRow.Place
        if let c = index { place = i < c ? .played : (i == c ? .current : .upcoming) } else { place = .upcoming }
        return RemovedRow(entry: entries[i], index: i, after: i > 0 ? entries[i - 1].id : nil, place: place, inSnapshot: inSnap, snapshotAfter: snapAfter)
    }

    /// Every row after the playing one, as removed rows (for "clear").
    func upcomingRemovedRows() -> [RemovedRow] {
        guard let c = index else { return [] }
        return ((c + 1)..<max(c + 1, entries.count)).compactMap { removedRow(at: $0) }
    }

    /// The hand-added rows after the playing one (what "Clear queue" removes).
    func manualRemovedRows() -> [RemovedRow] { upcomingRemovedRows().filter { $0.entry.isManual } }

    /// Puts removed rows back, each after the row it followed, or at its old position when that row is gone. Never into played rows, and
    /// rows that were already played are not restored. A row that is already in the queue is skipped. Returns how many came back.
    @discardableResult
    mutating func restore(_ rows: [RemovedRow]) -> Int {
        var n = 0
        for r in rows.sorted(by: { $0.index < $1.index }) where r.place != .played && !entries.contains(where: { $0.id == r.entry.id }) {
            var at: Int
            if let a = r.after, let k = entries.firstIndex(where: { $0.id == a }) { at = k + 1 } else { at = r.index }
            if let c = index { at = max(at, c + 1) }
            at = min(max(0, at), entries.count)
            // The autoplay rows stay the tail, whatever has joined the queue since the row left it.
            if !r.entry.auto, let c = index, let a = entries.indices.first(where: { $0 > c && entries[$0].auto }) { at = min(at, a) }
            entries.insert(r.entry, at: at)
            if r.inSnapshot, preShuffle != nil {
                if let a = r.snapshotAfter, let k = preShuffle?.firstIndex(where: { $0.id == a }) { preShuffle?.insert(r.entry, at: k + 1) }
                else if r.snapshotAfter == nil { preShuffle?.insert(r.entry, at: 0) }
                else { preShuffle?.append(r.entry) }
            } else if !r.entry.suggested, let snap = preShuffle, !snap.contains(where: { $0.id == r.entry.id }) {
                // Removed while shuffle was off and brought back while it is on: without a place in the unshuffled order, turning shuffle off would drop it.
                if let a = r.after, let k = snap.firstIndex(where: { $0.id == a }) { preShuffle?.insert(r.entry, at: k + 1) }
                else { preShuffle?.append(r.entry) }
            }
            n += 1
        }
        return n
    }

    /// Takes rows out again (redo of a removal). The playing row stays. Returns how many went.
    @discardableResult
    mutating func removeRows(ids: Set<Entry.ID>) -> Int {
        let gone = ids.subtracting(currentID.map { [$0] } ?? [])
        let present = Set(entries.map(\.id)).intersection(gone)
        guard !present.isEmpty else { return 0 }
        entries.removeAll { present.contains($0.id) }
        preShuffle?.removeAll { present.contains($0.id) }
        return present.count
    }

    /// Moves the row with this id to index `to` among the upcoming rows (clamped). False when it is not upcoming or did not move.
    @discardableResult
    mutating func moveRow(id: Entry.ID, to: Int) -> Bool {
        guard let c = index, let from = entries.firstIndex(where: { $0.id == id }), from > c else { return false }
        return moveUpcoming(from: from, to: min(max(to, c + 1), entries.count - 1))
    }
}
