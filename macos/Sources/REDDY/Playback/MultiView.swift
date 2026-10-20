import Foundation
import Observation

/// Two to four live channels playing side by side in their own window. Each tile has its own AVPlayer; only one is audible at a time.
/// The main player is stopped when multi-view starts so two sets of audio never overlap.
@MainActor @Observable
final class MultiViewModel {
    static let maxTiles = 4
    /// A stream that drops is reconnected this many times (with a growing pause) before the tile gives up.
    static let maxReconnects = 4
    var reconnectDelay: TimeInterval = 1.5

    @MainActor @Observable
    final class Tile: Identifiable {
        let id = UUID()
        let channel: Channel
        let engine: AVPlayerEngine
        var state: PlaybackState = .idle
        var failure: String?
        /// The underlying reason, shown small under the message so a problem can be diagnosed.
        var failureDetail: String?
        /// True while a dropped stream is being reconnected automatically.
        var reconnecting = false
        fileprivate var attempts = 0
        var isAudible = false
        /// What is on now, refreshed about once a minute.
        var programme: EPGProgram?
        fileprivate var task: Task<Void, Never>?
        fileprivate var watcher: Task<Void, Never>?
        init(channel: Channel, engine: AVPlayerEngine) { self.channel = channel; self.engine = engine }

        var isWorking: Bool { failure == nil && (reconnecting || state.isBusy || state == .idle) }
    }

    enum AddResult: Equatable { case added, alreadyShown, full }
    enum Layout: String, CaseIterable, Identifiable {
        case grid = "Grid", spotlight = "Spotlight"
        var id: String { rawValue }
        var symbol: String { self == .grid ? "square.grid.2x2" : "rectangle.leadinghalf.inset.filled" }
    }

    /// A saved set of channels ("Sunday football") that can be brought back with one click.
    struct Preset: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var channelIDs: [String]
    }

    private(set) var tiles: [Tile] = []
    var layout: Layout { didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) } }
    /// The big tile in Spotlight layout (the first tile when unset or gone).
    private(set) var spotlightID: UUID?
    /// A tile temporarily filling the whole window.
    private(set) var maximizedID: UUID?
    private(set) var isMuted = false
    private(set) var presets: [Preset] = []

    private let resolve: (Channel) throws -> PlaybackRequest
    private let makeEngine: () -> AVPlayerEngine
    private let willStart: () -> Void
    private let guide: ([String]) -> [String: EPGProgram]
    private let lookup: ([String]) -> [Channel]
    /// How many streams a playlist's subscription allows at once, when the provider says.
    private let connectionLimit: (UUID) -> Int?
    /// Channel search for the in-window picker: (text, favourites only) → channels.
    let find: (String, Bool) -> [Channel]
    private let defaults: UserDefaults
    private static let layoutKey = "multiview.layout", presetsKey = "multiview.presets"

    init(resolve: @escaping (Channel) throws -> PlaybackRequest, makeEngine: @escaping () -> AVPlayerEngine = { AVPlayerEngine() },
         willStart: @escaping () -> Void = {}, guide: @escaping ([String]) -> [String: EPGProgram] = { _ in [:] },
         lookup: @escaping ([String]) -> [Channel] = { _ in [] }, find: @escaping (String, Bool) -> [Channel] = { _, _ in [] },
         connectionLimit: @escaping (UUID) -> Int? = { _ in nil }, defaults: UserDefaults = .standard) {
        self.connectionLimit = connectionLimit
        self.resolve = resolve; self.makeEngine = makeEngine; self.willStart = willStart; self.guide = guide; self.lookup = lookup; self.find = find; self.defaults = defaults
        layout = defaults.string(forKey: Self.layoutKey).flatMap(Layout.init(rawValue:)) ?? .grid
        presets = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
    }

    var isFull: Bool { tiles.count >= Self.maxTiles }
    var audible: Tile? { tiles.first { $0.isAudible } }
    var maximized: Tile? { maximizedID.flatMap { id in tiles.first { $0.id == id } } }
    /// Columns for the grid: one tile fills the window, two sit side by side, three or four make a 2 × 2.
    var columns: Int { tiles.count <= 1 ? 1 : 2 }
    var spotlight: Tile? { tiles.first { $0.id == spotlightID } ?? tiles.first }
    var others: [Tile] { tiles.filter { $0.id != spotlight?.id } }

    // MARK: connection limit

    /// A channel the person chose that would go over the provider's limit, waiting for their answer.
    struct PendingAdd: Equatable { let channel: Channel; let message: String }
    var pendingAdd: PendingAdd?

    /// The warning for opening this channel now, or nil when it fits.
    func connectionWarning(adding channel: Channel) -> String? {
        ConnectionAdvice.message(tilesFromSource: tiles.filter { $0.channel.sourceID == channel.sourceID }.count, limit: connectionLimit(channel.sourceID))
    }

    /// Adds the channel, or first asks when it would go over the provider's limit.
    func requestAdd(_ channel: Channel) {
        if !tiles.contains(where: { $0.channel.id == channel.id }), !isFull, let message = connectionWarning(adding: channel) { pendingAdd = PendingAdd(channel: channel, message: message) }
        else { add(channel) }
    }

    func confirmPendingAdd() { if let p = pendingAdd { pendingAdd = nil; add(p.channel) } }
    func cancelPendingAdd() { pendingAdd = nil }

    // MARK: tiles

    @discardableResult
    func add(_ channel: Channel) -> AddResult {
        if tiles.contains(where: { $0.channel.id == channel.id }) { return .alreadyShown }
        guard !isFull else { return .full }
        if tiles.isEmpty { willStart() }
        let tile = makeTile(channel)
        tiles.append(tile)
        if audible == nil { setAudible(tile.id) }
        refreshGuide()
        return .added
    }

    /// Puts another channel into an existing tile, keeping its place and its sound.
    func replace(_ id: UUID, with channel: Channel) {
        guard let i = tiles.firstIndex(where: { $0.id == id }), !tiles.contains(where: { $0.channel.id == channel.id }) else { return }
        let old = tiles[i]
        let tile = makeTile(channel)
        tiles[i] = tile
        shutdown(old)
        if spotlightID == old.id { spotlightID = tile.id }
        if maximizedID == old.id { maximizedID = tile.id }
        if old.isAudible { setAudible(tile.id) }
        refreshGuide()
    }

    func remove(_ id: UUID) {
        guard let i = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: i)
        shutdown(tile)
        if maximizedID == id { maximizedID = nil }
        if spotlightID == id { spotlightID = nil }
        if tile.isAudible, let next = tiles.first { setAudible(next.id) }
    }

    func removeAll() {
        let all = tiles; tiles = []; spotlightID = nil; maximizedID = nil
        all.forEach(shutdown)
    }

    func retry(_ id: UUID) { if let t = tiles.first(where: { $0.id == id }) { t.attempts = 0; t.failure = nil; t.failureDetail = nil; load(t) } }

    // MARK: sound and focus

    func setAudible(_ id: UUID) {
        isMuted = false
        for t in tiles {
            t.isAudible = t.id == id
            let wantMuted = t.id != id
            if t.engine.player.isMuted != wantMuted { t.engine.setMuted(wantMuted) }       // leave the other streams alone
            if !wantMuted, t.engine.player.volume != 1 { t.engine.setVolume(1) }
        }
    }

    /// Silences everything, or gives the sound back to the tile that had it.
    func toggleMute() {
        isMuted.toggle()
        if isMuted { tiles.forEach { if !$0.engine.player.isMuted { $0.engine.setMuted(true) } } }
        else if let a = audible ?? tiles.first { setAudible(a.id) }
    }

    /// Selects the tile by position (1…4), as the number keys do.
    func selectTile(at index: Int) { if tiles.indices.contains(index) { setAudible(tiles[index].id) } }

    func makeSpotlight(_ id: UUID) {
        guard tiles.contains(where: { $0.id == id }) else { return }
        spotlightID = id; layout = .spotlight; setAudible(id)
    }

    func toggleMaximize(_ id: UUID) {
        guard tiles.contains(where: { $0.id == id }) else { return }
        maximizedID = maximizedID == id ? nil : id
        if maximizedID != nil { setAudible(id) }
    }

    func restoreFromMaximize() { maximizedID = nil }

    // MARK: presets

    func savePreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !tiles.isEmpty else { return }
        let ids = tiles.map(\.channel.id)
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { presets[i].channelIDs = ids }
        else { presets.append(Preset(name: n, channelIDs: ids)) }
        persistPresets()
    }

    func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id }; persistPresets() }

    /// Replaces what is showing with the preset's channels. Channels that no longer exist are skipped; returns how many were found.
    @discardableResult
    func load(_ preset: Preset) -> Int {
        let found = lookup(preset.channelIDs)
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        removeAll()
        for id in preset.channelIDs { if let c = byID[id] { add(c) } }
        return tiles.count
    }

    // MARK: guide

    /// What is on now for arbitrary channels (used by the picker).
    func programmes(for ids: [String]) -> [String: EPGProgram] { guide(ids) }

    func refreshGuide() {
        let now = guide(tiles.map(\.channel.id))
        for t in tiles { t.programme = now[t.channel.id] }
    }

    // MARK: internals

    private func makeTile(_ channel: Channel) -> Tile {
        let tile = Tile(channel: channel, engine: makeEngine())
        tile.engine.setMuted(true)
        start(tile)
        return tile
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
    }

    /// Watches the engine for the life of the tile (one watcher only: the engine's state stream has a single consumer) and loads it.
    private func start(_ tile: Tile) {
        let engine = tile.engine
        tile.watcher = Task { [weak self, weak tile] in
            for await s in engine.stateUpdates {
                guard let self, let tile else { return }
                tile.state = s
                switch s {
                case .playing:
                    tile.attempts = 0; tile.reconnecting = false; tile.failure = nil; tile.failureDetail = nil
                case .failed(let e):
                    self.dropped(tile, e)
                default: break
                }
            }
        }
        load(tile)
    }

    private func load(_ tile: Tile) {
        tile.task?.cancel()
        let engine = tile.engine
        tile.task = Task { [weak self, weak tile] in
            guard let tile else { return }
            do {
                guard let self else { return }
                let request = try self.resolve(tile.channel)
                try await engine.load(request)
                try await engine.play()
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.dropped(tile, (error as? PlaybackError) ?? PlaybackError(.unknown, detail: "\(error)"))
            }
        }
    }

    /// A stream failed or ended. Live streams drop now and then (provider limits, network blips), so reconnect a few times
    /// before showing an error.
    private func dropped(_ tile: Tile, _ error: PlaybackError) {
        guard tiles.contains(where: { $0.id == tile.id }) else { return }
        if tile.attempts < Self.maxReconnects {
            tile.attempts += 1
            tile.reconnecting = true
            let wait = reconnectDelay * Double(tile.attempts)
            tile.task?.cancel()
            tile.task = Task { [weak self, weak tile] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self, let tile, self.tiles.contains(where: { $0.id == tile.id }) else { return }
                self.load(tile)
            }
        } else {
            tile.reconnecting = false
            tile.failure = error.message
            tile.failureDetail = error.detail
        }
    }

    private func shutdown(_ tile: Tile) {
        tile.task?.cancel(); tile.watcher?.cancel()
        tile.engine.stop()
    }
}
