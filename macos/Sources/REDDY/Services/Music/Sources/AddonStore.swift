import Foundation
import Observation

// The list of addons the person added. Nothing exists until they add one: no catalogue ships and no addon is contacted before then.
// The address is kept in the Keychain (it may carry a private token in its path) together with any access token; the JSON file holds only labels and switches.

/// When addons take part, by the person's quality choice. Addons can be slow, so the person decides how often they are asked.
enum AddonQualityPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case losslessOnly, highAndUp, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .losslessOnly: "Only when quality is Lossless"
        case .highAndUp: "When quality is High or Lossless"
        case .always: "At every quality"
        }
    }
    func allows(_ q: MusicQuality) -> Bool {
        switch self {
        case .losslessOnly: q == .lossless
        case .highAndUp: q >= .high
        case .always: true
        }
    }
}

struct AddonHealth: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case unknown, ok, unreachable, rejected }
    var state: State = .unknown
    var detail: String = ""
    var latencyMs: Int? = nil
    var checkedAt: Date? = nil

    static func from(_ p: AddonProblem, at: Date) -> AddonHealth {
        switch p {
        case .unreachable(let s): AddonHealth(state: .unreachable, detail: s, latencyMs: nil, checkedAt: at)
        case .blocked(let s), .rejected(let s), .notRecognised(let s), .unsupported(let s), .duplicate(let s): AddonHealth(state: .rejected, detail: s, latencyMs: nil, checkedAt: at)
        }
    }
}

struct AddonConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The person's own name for it; blank falls back to the manifest name, then the host.
    var label: String
    var host: String
    var manifestName: String?
    var version: String?
    var enabled: Bool = true
    var ownServer: Bool = false
    var allowDownloads: Bool = true
    var qualityOptions: [AddonOption] = []
    var pickedQuality: String?
    /// False when the manifest lists resources but not `stream` and rows do not carry their own address; the addon is then search-only and not used.
    var canStream: Bool = true
    var health: AddonHealth = AddonHealth()

    var displayName: String {
        let l = label.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? (manifestName ?? host) : l
    }
    /// A picked quality is dropped when the addon stops listing it.
    var activeQuality: String? { pickedQuality.flatMap { p in qualityOptions.contains { $0.value == p } ? p : nil } ?? qualityOptions.first?.value }
}

/// What one test run found, shown line by line.
struct AddonTestReport: Sendable {
    struct Step: Sendable, Hashable { var name: String; var ok: Bool; var detail: String }
    var steps: [Step] = []
    var health = AddonHealth()
    var identity: AddonIdentity?
    var manifest: AddonManifest?
    var ok: Bool { health.state == .ok }
}

enum AddonTester {
    /// Probes an address the way the Test button does: the manifest, then a search for "music", then a stream for the first row. Saves nothing.
    static func run(_ raw: String, ownServer: Bool, token: String?, http: MusicHTTP = MusicHTTP(), now: @escaping @Sendable () -> Date = { Date() },
                    sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) async -> AddonTestReport {
        var report = AddonTestReport()
        var t = AddonTransport(http: http, token: token, ownServer: ownServer); t.now = now; t.sleep = sleep
        let identity: AddonIdentity
        do { identity = try await AddonFormatDetector.identify(raw, ownServer: ownServer, token: token, http: http, transport: t) }
        catch {
            let p = AddonProblem.classify(error)
            report.steps.append(.init(name: "Manifest", ok: false, detail: p.message))
            report.health = .from(p, at: now())
            return report
        }
        report.identity = identity; report.manifest = identity.manifest
        report.steps.append(.init(name: "Manifest", ok: true, detail: identity.hasManifest
            ? identity.manifest.displayName + (identity.manifest.version.map { " v\($0)" } ?? "") : "No manifest, but search answers"))
        let client = AddonClient(endpoint: AddonEndpoint(id: "test", name: identity.manifest.displayName, base: identity.base, token: token, ownServer: ownServer,
                                                         pickedQuality: identity.manifest.qualityOptions.first?.value), http: http, now: now, sleep: sleep)
        let started = now()
        let rows: [AddonRow]
        do { rows = try await client.search(q: "music", request: .best) }
        catch {
            let p = AddonProblem.classify(error)
            report.steps.append(.init(name: "Search", ok: false, detail: p.message))
            report.health = .from(p, at: now())
            return report
        }
        let ms = Int(now().timeIntervalSince(started) * 1000)
        report.steps.append(.init(name: "Search", ok: true, detail: rows.isEmpty ? "Works, no results for \"music\"" : "\(rows.count) results"))
        var detail = identity.hasManifest ? identity.manifest.displayName + (identity.manifest.version.map { " v\($0)" } ?? "") : "No manifest · search works"
        if let row = rows.first {
            do {
                switch try await client.stream(row: row, request: .best) {
                case .stream(let r): report.steps.append(.init(name: "Stream", ok: true, detail: r.quality.summary))
                case .miss(let why): report.steps.append(.init(name: "Stream", ok: false, detail: why)); detail += " · stream: \(why)"
                }
            } catch {
                let p = AddonProblem.classify(error)
                report.steps.append(.init(name: "Stream", ok: false, detail: p.message)); detail += " · stream not answering"
            }
        } else {
            report.steps.append(.init(name: "Stream", ok: true, detail: "Not tried, nothing to play"))
        }
        report.health = AddonHealth(state: .ok, detail: detail, latencyMs: ms, checkedAt: now())
        return report
    }
}

@MainActor @Observable
final class AddonStore {
    /// The store the Sources screen uses when the hub has not been given one.
    static let shared = AddonStore()

    private(set) var addons: [AddonConfig] = []
    var qualityPolicy: AddonQualityPolicy = .highAndUp { didSet { if oldValue != qualityPolicy { persist() } } }
    /// Check how big the audio file is before trusting an addon's stream (catches 30 second previews under a full length row).
    var checkFileLength: Bool = false { didSet { if oldValue != checkFileLength { persist() } } }
    private(set) var busy: Set<UUID> = []

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let secrets: any ScrobbleSecretStore
    @ObservationIgnored private let http: MusicHTTP
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var clients: [UUID: AddonClient] = [:]

    static var defaultDirectory: URL { MusicStorage.subfolder("Sources") }

    private struct FileShape: Codable { var policy: AddonQualityPolicy?; var checkFileLength: Bool?; var addons: [AddonConfig] }

    init(directory: URL = AddonStore.defaultDirectory, secrets: any ScrobbleSecretStore = ScrobbleKeychainStore(), http: MusicHTTP = MusicHTTP(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = directory.appendingPathComponent("addons.json")
        self.secrets = secrets; self.http = http; self.now = now
        load()
    }

    // MARK: lookups

    var hasEnabledAddon: Bool { addons.contains { $0.enabled } }
    func config(_ id: UUID) -> AddonConfig? { addons.first { $0.id == id } }

    private func urlAccount(_ id: UUID) -> String { "addon.\(id.uuidString).url" }
    private func tokenAccount(_ id: UUID) -> String { "addon.\(id.uuidString).token" }

    func endpoint(for c: AddonConfig) -> AddonEndpoint? {
        guard let text = secrets.read(urlAccount(c.id)), let url = URL(string: text) else { return nil }
        return AddonEndpoint(id: c.id.uuidString, name: c.displayName, base: url, token: secrets.read(tokenAccount(c.id)), ownServer: c.ownServer,
                             pickedQuality: c.activeQuality, allowDownloads: c.allowDownloads)
    }

    func client(for c: AddonConfig) -> AddonClient? {
        if let existing = clients[c.id], existing.endpoint.pickedQuality == c.activeQuality, existing.endpoint.ownServer == c.ownServer { return existing }
        guard let e = endpoint(for: c) else { return nil }
        let made = AddonClient(endpoint: e, http: http, now: now)
        clients[c.id] = made
        return made
    }

    /// Enabled, complete addons in the person's order that this quality setting allows.
    func activeProviders(for quality: MusicQuality) -> [(config: AddonConfig, provider: AddonAudioProvider)] {
        guard qualityPolicy.allows(quality) else { return [] }
        return addons.compactMap { c in
            guard c.enabled, c.canStream, let cl = client(for: c) else { return nil }
            return (c, AddonAudioProvider(client: cl, displayName: c.displayName))
        }
    }

    // MARK: adding and testing

    private func existingAddon(matching base: URL) -> AddonConfig? {
        addons.first { c in secrets.read(urlAccount(c.id)).flatMap { AddonFormatDetector.canonicalBase($0) }?.absoluteString == base.absoluteString }
    }

    /// Runs the Test button's probe. Nothing is saved.
    func test(_ raw: String, ownServer: Bool, token: String?) async -> AddonTestReport {
        var report = await AddonTester.run(raw, ownServer: ownServer, token: token.flatMap { $0.isEmpty ? nil : $0 }, http: http, now: now)
        if let base = report.identity?.base, let dup = existingAddon(matching: base) {
            report.steps.append(.init(name: "Already added", ok: false, detail: "Already added as \(dup.displayName)"))
        }
        return report
    }

    /// Adds an addon after identifying it. A server that is asleep right now is still worth keeping once its format was recognised, so a failed
    /// health probe does not block saving; only an unrecognised, blocked or duplicate address does.
    @discardableResult
    func add(_ raw: String, label: String = "", token: String? = nil, ownServer: Bool = false) async throws -> AddonConfig {
        let tok = token.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let started = now()
        let identity = try await AddonFormatDetector.identify(raw, ownServer: ownServer, token: tok, http: http)
        if let dup = existingAddon(matching: identity.base) { throw AddonProblem.duplicate("Already added as \(dup.displayName)") }
        let m = identity.manifest
        let canStream = m.resources.isEmpty || m.resources.contains("stream")
        let options = m.qualityOptions
        let config = AddonConfig(id: UUID(), label: label.trimmingCharacters(in: .whitespacesAndNewlines), host: identity.base.host ?? "addon",
                                 manifestName: identity.hasManifest ? m.displayName : nil, version: m.version, enabled: true, ownServer: ownServer,
                                 allowDownloads: m.allowDownloads, qualityOptions: options, pickedQuality: nil, canStream: canStream,
                                 health: AddonHealth(state: .ok, detail: identity.hasManifest ? m.displayName + (m.version.map { " v\($0)" } ?? "") : "No manifest · search works",
                                                     latencyMs: Int(now().timeIntervalSince(started) * 1000), checkedAt: now()))
        secrets.write(identity.base.absoluteString, account: urlAccount(config.id))
        if let tok { secrets.write(tok, account: tokenAccount(config.id)) }
        addons.append(config)
        persist()
        return config
    }

    /// Re-runs the probe for an addon and records the result as its health.
    @discardableResult
    func test(_ id: UUID) async -> AddonTestReport? {
        guard let c = config(id), let url = secrets.read(urlAccount(id)) else { return nil }
        busy.insert(id); defer { busy.remove(id) }
        let report = await AddonTester.run(url, ownServer: c.ownServer, token: secrets.read(tokenAccount(id)), http: http, now: now)
        update(id) { cfg in
            cfg.health = report.health
            if let m = report.manifest {
                cfg.manifestName = report.identity?.hasManifest == true ? m.displayName : nil
                cfg.version = m.version; cfg.allowDownloads = m.allowDownloads
                cfg.qualityOptions = m.qualityOptions
                cfg.canStream = m.resources.isEmpty || m.resources.contains("stream")
                if let p = cfg.pickedQuality, !m.qualityOptions.contains(where: { $0.value == p }) { cfg.pickedQuality = nil }
            }
        }
        return report
    }

    func testAll() async { for c in addons where c.enabled { await test(c.id) } }

    // MARK: editing

    private func update(_ id: UUID, _ change: (inout AddonConfig) -> Void) {
        guard let i = addons.firstIndex(where: { $0.id == id }) else { return }
        change(&addons[i]); clients[id] = nil; persist()
    }

    func setEnabled(_ on: Bool, id: UUID) { update(id) { $0.enabled = on } }
    func setLabel(_ s: String, id: UUID) { update(id) { $0.label = s } }
    func setPickedQuality(_ value: String?, id: UUID) { update(id) { $0.pickedQuality = value } }
    func setAllowDownloads(_ on: Bool, id: UUID) { update(id) { $0.allowDownloads = on } }

    /// Drag-and-drop order. The list order is the priority; there is no separate priority number.
    func move(from: IndexSet, to: Int) {
        guard addons.count > 1 else { return }
        let moving = from.sorted().map { addons[$0] }
        var rest = addons.enumerated().filter { !from.contains($0.offset) }.map(\.element)
        let before = from.filter { $0 < to }.count
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, to - before)))
        guard rest != addons else { return }
        addons = rest; persist()
    }

    /// Order by id list: unknown ids are dropped, omitted ones keep their relative order at the end.
    func reorder(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let ordered = ids.compactMap { id in addons.first { $0.id == id } }.filter { seen.insert($0.id).inserted }
        let rest = addons.filter { !seen.contains($0.id) }
        guard ordered + rest != addons else { return }
        addons = ordered + rest; persist()
    }

    func remove(_ id: UUID) {
        secrets.remove(urlAccount(id)); secrets.remove(tokenAccount(id))
        addons.removeAll { $0.id == id }; clients[id] = nil; persist()
    }

    /// Privacy wipe: every addon, its address and token.
    func removeAll() { for a in addons { secrets.remove(urlAccount(a.id)); secrets.remove(tokenAccount(a.id)) }; addons = []; clients = [:]; persist() }

    // MARK: persistence

    private func persist() {
        let shape = FileShape(policy: qualityPolicy, checkFileLength: checkFileLength, addons: addons)
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let shape = try? JSONDecoder().decode(FileShape.self, from: data) else {
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("bad"))
            return
        }
        addons = shape.addons
        qualityPolicy = shape.policy ?? .highAndUp
        checkFileLength = shape.checkFileLength ?? false
    }
}
