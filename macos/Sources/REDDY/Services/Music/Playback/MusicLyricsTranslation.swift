import Foundation
import CryptoKit
import NaturalLanguage
import Observation
#if canImport(Translation)
import Translation
#endif

// Translation and romanisation of the lyrics on screen, shown as a second small line under each original line. Translation runs on the
// device with Apple's Translation framework, so no lyric leaves the Mac or iPhone. Romanisation uses the local engine. Both produce
// per-line data that the lyrics view draws; the original lines are never changed.

// MARK: - per-line data

enum MusicLyricsSubKind: String, Codable, Sendable { case translation, romanization }

struct MusicLyricSubLine: Codable, Hashable, Sendable {
    var text: String
    /// The same for the line's background vocal, when it has one.
    var background: String? = nil
}

/// A translation or a romanisation of one lyric: entry `i` belongs to line `i` of the lyric (nil when the line has nothing to show).
struct MusicLyricsSubLines: Codable, Hashable, Sendable {
    var kind: MusicLyricsSubKind
    var target: String
    var source: String
    var lines: [MusicLyricSubLine?]

    /// The text to draw under line `index`: nil when missing or when it only repeats the original (trimmed, case-insensitive).
    func display(for index: Int, original: String) -> MusicLyricSubLine? {
        guard lines.indices.contains(index), let l = lines[index] else { return nil }
        let same = l.text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(original.trimmingCharacters(in: .whitespaces)) == .orderedSame
        if same, (l.background ?? "").isEmpty { return nil }
        return same ? MusicLyricSubLine(text: "", background: l.background) : l
    }

    /// How far the translated text is sung when the original line is at `position`: the original's character progress projected on the
    /// translated length, so holds and pauses carry over.
    static func revealedChars(original line: MusicLyricLine, position: Int64, translatedLength: Int) -> Int {
        let total = max(1, line.text.count)
        let done = line.revealedChars(at: position)
        return min(translatedLength, Int((Double(done) / Double(total) * Double(translatedLength)).rounded(.down)))
    }
}

enum MusicLyricsTranslationState: Equatable, Sendable {
    case idle
    case loading
    case ready(MusicLyricsSubLines)
    /// The lyrics are already in the target language (translation), or already in Latin letters (romanisation).
    case unchanged
    case unavailable(String)

    var subLines: MusicLyricsSubLines? { if case .ready(let s) = self { return s }; return nil }
}

// MARK: - slots

/// One piece of text that goes to the translator: a line, or a line's background vocal. Section markers like `[Chorus]` travel without
/// their brackets and get them back afterwards.
struct MusicLyricsSlot: Hashable, Sendable {
    var lineIndex: Int
    var background: Bool
    var text: String
    var wrapped: Bool
}

enum MusicLyricsSlots {
    /// The lines of the lyric the translation covers: timed lines, or the plain text split into lines.
    static func lines(of lyrics: MusicLyrics) -> [MusicLyricLine] {
        if let s = lyrics.synced, !s.isEmpty { return s }
        return (lyrics.plain ?? "").replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { MusicLyricLine(timeMs: 0, text: String($0)) }
    }

    static func build(_ lines: [MusicLyricLine]) -> [MusicLyricsSlot] {
        var out: [MusicLyricsSlot] = []
        for (i, l) in lines.enumerated() {
            let lead = leadText(l).trimmingCharacters(in: .whitespacesAndNewlines)
            if !lead.isEmpty {
                let marker = lead.hasPrefix("[") && lead.hasSuffix("]") && lead.count > 2
                out.append(MusicLyricsSlot(lineIndex: i, background: false, text: marker ? String(lead.dropFirst().dropLast()) : lead, wrapped: marker))
            }
            if let bg = backgroundText(l)?.trimmingCharacters(in: .whitespacesAndNewlines), !bg.isEmpty {
                out.append(MusicLyricsSlot(lineIndex: i, background: true, text: bg, wrapped: false))
            }
        }
        return out
    }

    /// The lead text without its background tail.
    static func leadText(_ l: MusicLyricLine) -> String {
        if let words = l.words, words.contains(where: \.background) {
            return MusicLyricsText.collapsed(words.filter { !$0.background }.map(\.text).joined())
        }
        if let b = l.backgroundText, let r = l.text.range(of: b, options: .backwards) { return String(l.text[..<r.lowerBound]) }
        return l.text
    }

    static func backgroundText(_ l: MusicLyricLine) -> String? {
        if let words = l.words, words.contains(where: \.background) {
            return MusicLyricsSyllables.displayBackground(MusicLyricsText.collapsed(words.filter(\.background).map(\.text).joined()))
        }
        return l.backgroundText.map(MusicLyricsSyllables.displayBackground)
    }

    /// Puts translated slot texts back under their lines.
    static func assemble(lineCount: Int, slots: [MusicLyricsSlot], texts: [String]) -> [MusicLyricSubLine?] {
        var out: [MusicLyricSubLine?] = Array(repeating: nil, count: lineCount)
        for (s, t) in zip(slots, texts) {
            let text = s.wrapped ? "[\(t)]" : t
            var line = out[s.lineIndex] ?? MusicLyricSubLine(text: "")
            if s.background { line.background = text } else { line.text = text }
            out[s.lineIndex] = line
        }
        return out
    }
}

// MARK: - languages

enum MusicTranslationLanguage {
    /// A short tag in the form the Translation framework uses: legacy aliases mapped (iw to he, in to id, ji to yi), the Chinese script kept
    /// (zh-Hans, zh-Hant), everything else reduced to the base language; blank means English.
    static func canonical(_ tag: String?) -> String {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "en" }
        let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        var base = (parts.first ?? "en").lowercased()
        switch base { case "iw": base = "he"; case "in": base = "id"; case "ji": base = "yi"; default: break }
        if base == "zh" || base == "yue" {
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) { return "zh-Hant" }
            return "zh-Hans"
        }
        return base
    }

    /// The same language; Chinese in a different script is not the same.
    static func same(_ a: String?, _ b: String?) -> Bool { canonical(a) == canonical(b) }

    /// The language of the lyric text, or nil when it cannot be told.
    static func detect(_ texts: [String]) -> String? {
        let sample = String(texts.joined(separator: "\n").prefix(4000))
        guard !sample.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        return r.dominantLanguage.map { canonical($0.rawValue) }
    }
}

// MARK: - gzip (own files only)

/// Writes and reads gzip files: a ten byte header, raw deflate, the CRC-32 and the length. The cache is the only user.
enum MusicGzip {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func compress(_ data: Data) -> Data? {
        guard let body = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(body)
        var crc = crc32(data).littleEndian, size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4)); out.append(Data(bytes: &size, count: 4))
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 0x08, b[3] == 0 else { return nil }
        let body = Data(b[10..<(b.count - 8)])
        guard let raw = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let tail = Array(b[(b.count - 8)...])
        let crc = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
        let size = UInt32(tail[4]) | UInt32(tail[5]) << 8 | UInt32(tail[6]) << 16 | UInt32(tail[7]) << 24
        return crc == crc32(raw) && size == UInt32(truncatingIfNeeded: raw.count) ? raw : nil
    }
}

// MARK: - cache

/// Translated slot texts, kept 12 in memory (least recently used out) and as gzip files on disk, 2 MiB at most, oldest out.
final class MusicLyricsTranslationCache: @unchecked Sendable {
    static let version = 3
    static let memoryLimit = 12
    static let diskLimit = 2 * 1_048_576

    struct Entry: Codable, Equatable, Sendable {
        var version: Int
        var source: String
        var target: String
        var texts: [String]
    }

    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private var order: [String] = []
    private let directory: URL?

    init(directory: URL?) {
        if let directory {
            let d = directory.appendingPathComponent("v\(Self.version)", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            self.directory = d
        } else { self.directory = nil }
    }

    /// SHA-256 over the track id, a NUL, the target, then each slot text preceded by a NUL. Romanisation passes the literal "romanize".
    static func key(trackID: String, target: String, slots: [String]) -> String {
        var data = Data(trackID.utf8); data.append(0); data.append(Data(target.utf8))
        for s in slots { data.append(0); data.append(Data(s.utf8)) }
        return MusicHash.sha256(data)
    }

    func get(_ key: String, slotCount: Int) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if let e = memory[key], valid(e, slotCount) { touch(key); return e }
        guard let url = file(key), let raw = try? Data(contentsOf: url), let json = MusicGzip.decompress(raw),
              let e = try? JSONDecoder().decode(Entry.self, from: json), valid(e, slotCount) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        remember(key, e)
        return e
    }

    func put(_ key: String, _ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        remember(key, entry)
        guard let url = file(key), let json = try? JSONEncoder().encode(entry), let gz = MusicGzip.compress(json) else { return }
        let temp = url.appendingPathExtension("tmp")
        do { try gz.write(to: temp); _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) } catch { try? FileManager.default.removeItem(at: temp); return }
        trimDisk()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        memory = [:]; order = []
        if let d = directory, let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    var memoryCount: Int { lock.lock(); defer { lock.unlock() }; return memory.count }

    private func valid(_ e: Entry, _ count: Int) -> Bool { e.version == Self.version && e.texts.count == count }
    private func file(_ key: String) -> URL? { directory?.appendingPathComponent(key + ".json.gz") }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func remember(_ key: String, _ e: Entry) {
        memory[key] = e; touch(key)
        while order.count > Self.memoryLimit, let oldest = order.first { order.removeFirst(); memory[oldest] = nil }
    }

    /// Newest first; everything past the cumulative limit is deleted.
    private func trimDisk() {
        guard let d = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let rows = files.filter { $0.pathExtension == "gz" }.map { f -> (URL, Date, Int) in
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (f, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for r in rows {
            total += r.2
            if total > Self.diskLimit { try? FileManager.default.removeItem(at: r.0) }
        }
    }
}

// MARK: - the translator

enum MusicTranslatorAvailability: Equatable, Sendable {
    /// The language pair is installed and can run now.
    case ready
    /// Supported; the system asks the person to download the language the first time.
    case needsDownload
    case unsupported
    /// This system is too old, or the translator is not connected.
    case unavailable
}

protocol MusicLyricsTextTranslator: Sendable {
    func availability(source: String?, target: String) async -> MusicTranslatorAvailability
    /// Translates each text and returns the answers in the same order. Throws when the system cannot translate right now.
    func translate(_ texts: [String], source: String?, target: String) async throws -> [String]
}

// MARK: - the service

@MainActor @Observable
final class MusicLyricsTranslationService {
    private(set) var translation: MusicLyricsTranslationState = .idle
    private(set) var romanization: MusicLyricsTranslationState = .idle
    /// The language in the status line, for example "These lyrics are already in {language}".
    private(set) var targetLanguage = "en"

    @ObservationIgnored private var translator: (any MusicLyricsTextTranslator)?
    @ObservationIgnored private let cache: MusicLyricsTranslationCache
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(cacheDirectory: URL?, translator: (any MusicLyricsTextTranslator)? = nil) {
        self.cache = MusicLyricsTranslationCache(directory: cacheDirectory)
        self.translator = translator
    }

    /// Connected by the app once the system translator exists (see `MusicAppleTranslationBridge`).
    func connect(_ translator: (any MusicLyricsTextTranslator)?) { self.translator = translator }
    var isAvailable: Bool { translator != nil }

    /// A new song, lyric or language: whatever was running stops and both states reset.
    func reset() {
        job?.cancel(); job = nil
        generation += 1
        translation = .idle; romanization = .idle
    }

    func clearCache() { cache.clear() }

    func requestTranslation(of lyrics: MusicLyrics, trackID: String, target: String?) {
        job?.cancel()
        generation += 1
        let gen = generation
        let tgt = MusicTranslationLanguage.canonical(target ?? Locale.current.language.languageCode?.identifier)
        targetLanguage = tgt
        translation = .loading
        job = Task { [weak self] in
            guard let self else { return }
            let result = await self.runTranslation(lyrics, trackID: trackID, target: tgt)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.translation = result
        }
    }

    /// Romanises with the local engine; Latin-only lyrics report `unchanged`. It is immediate, so it never touches a translation that is running (cancelling it
    /// would leave the panel saying "Translating" for good).
    func requestRomanization(of lyrics: MusicLyrics) {
        romanization = Self.romanize(MusicLyricsSlots.lines(of: lyrics))
    }

    // MARK: work

    private func runTranslation(_ lyrics: MusicLyrics, trackID: String, target: String) async -> MusicLyricsTranslationState {
        let lines = MusicLyricsSlots.lines(of: lyrics)
        let slots = MusicLyricsSlots.build(lines)
        guard !slots.isEmpty else { return .unavailable("There is no text to translate") }
        let texts = slots.map(\.text)
        let source = MusicTranslationLanguage.detect(texts)
        if let source, MusicTranslationLanguage.same(source, target) { return .unchanged }
        let key = MusicLyricsTranslationCache.key(trackID: trackID, target: target, slots: texts)
        if let hit = cache.get(key, slotCount: texts.count) {
            return .ready(MusicLyricsSubLines(kind: .translation, target: target, source: hit.source,
                                              lines: MusicLyricsSlots.assemble(lineCount: lines.count, slots: slots, texts: hit.texts)))
        }
        guard let translator else { return .unavailable("Translation is not available on this device") }
        switch await translator.availability(source: source, target: target) {
        case .unsupported: return .unavailable("This language pair is not supported for on-device translation")
        case .unavailable: return .unavailable("Translation needs a newer version of the operating system")
        case .ready, .needsDownload: break
        }
        do {
            let out = try await translator.translate(texts, source: source, target: target)
            guard out.count == texts.count, !out.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return .unavailable("Translation is unavailable right now")
            }
            cache.put(key, MusicLyricsTranslationCache.Entry(version: MusicLyricsTranslationCache.version, source: source ?? "", target: target, texts: out))
            return .ready(MusicLyricsSubLines(kind: .translation, target: target, source: source ?? "",
                                              lines: MusicLyricsSlots.assemble(lineCount: lines.count, slots: slots, texts: out)))
        } catch is CancellationError {
            return .idle
        } catch {
            return .unavailable("Translation is unavailable right now")
        }
    }

    nonisolated static func romanize(_ lines: [MusicLyricLine]) -> MusicLyricsTranslationState {
        let texts = lines.map(\.text)
        guard texts.contains(where: { !MusicLyricsText.hasLatinOnly($0) }) else { return .unchanged }
        let japanese = MusicRomanizer.isJapanese(texts: texts)
        var out: [MusicLyricSubLine?] = []
        var any = false
        for l in lines {
            let t = MusicLyricsSlots.leadText(l)
            if let r = MusicRomanizer.reading(of: t, japanese: japanese), !r.isEmpty, MusicLyricsText.collapsed(r) != MusicLyricsText.collapsed(t) {
                var sub = MusicLyricSubLine(text: r)
                if let bg = MusicLyricsSlots.backgroundText(l), let br = MusicRomanizer.reading(of: bg, japanese: japanese), !br.isEmpty { sub.background = br }
                out.append(sub); any = true
            } else { out.append(nil) }
        }
        return any ? .ready(MusicLyricsSubLines(kind: .romanization, target: "Latn", source: "", lines: out)) : .unavailable("Romanization is unavailable for these lyrics")
    }

    /// The line the status row shows, in the order of precedence of the spec.
    func statusLine(languageName: String) -> String? {
        switch (translation, romanization) {
        case (.loading, _): return Localized.string("Translating to %@...", languageName)
        case (_, .loading): return Localized.string("Romanizing lyrics...")
        case (.ready, _): return Localized.string("Translated to %@", languageName)
        case (_, .ready): return Localized.string("Romanized pronunciation")
        case (.unchanged, _): return Localized.string("These lyrics are already in %@", languageName)
        case (_, .unchanged): return Localized.string("These lyrics already use Latin characters")
        case (.unavailable(let m), _): return Localized.string(m)
        case (_, .unavailable(let m)): return Localized.string(m)
        default: return nil
        }
    }
}

// MARK: - Apple's Translation framework

#if canImport(Translation)
/// Runs translations on the device. On the newest systems it opens a session for installed languages by itself; on macOS 15 and iOS 18
/// (and when a language still has to be downloaded) the system only hands out a session to a view, so the lyrics view attaches
/// `.translationTask(bridge.configuration) { session in await bridge.serve(session) }` and the bridge feeds it the waiting job.
@available(macOS 15.0, iOS 18.0, *)
@MainActor @Observable
final class MusicAppleTranslationBridge: MusicLyricsTextTranslator {
    /// Set when a job waits for a view's session; the view's `translationTask` runs when it changes.
    var configuration: TranslationSession.Configuration?

    private struct Pending {
        var texts: [String]
        var continuation: CheckedContinuation<[String], Error>
    }
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init() {}

    nonisolated func availability(source: String?, target: String) async -> MusicTranslatorAvailability {
        let avail = LanguageAvailability()
        let tgt = Locale.Language(identifier: target)
        let status: LanguageAvailability.Status
        if let source, !source.isEmpty { status = await avail.status(from: Locale.Language(identifier: source), to: tgt) } else { return .needsDownload }
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    nonisolated func translate(_ texts: [String], source: String?, target: String) async throws -> [String] {
        if #available(macOS 26.0, iOS 26.0, *), let source, !source.isEmpty {
            let tgt = Locale.Language(identifier: target)
            if await LanguageAvailability().status(from: Locale.Language(identifier: source), to: tgt) == .installed {
                let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: tgt)
                let answers = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
                return answers.map(\.targetText)
            }
        }
        return try await viaView(texts, source: source, target: target)
    }

    private func viaView(_ texts: [String], source: String?, target: String) async throws -> [String] {
        timeout?.cancel()
        pending?.continuation.resume(throwing: CancellationError())
        pending = nil
        return try await withCheckedThrowingContinuation { cont in
            pending = Pending(texts: texts, continuation: cont)
            let src = source.flatMap { $0.isEmpty ? nil : Locale.Language(identifier: $0) }
            configuration = TranslationSession.Configuration(source: src, target: Locale.Language(identifier: target))
            // Nobody to run the session (no lyrics view on screen): give up rather than wait forever.
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard !Task.isCancelled else { return }
                self?.fail(MusicError.unsupported("translation"))
            }
        }
    }

    private func fail(_ error: Error) {
        guard let p = pending else { return }
        pending = nil; configuration = nil
        p.continuation.resume(throwing: error)
    }

    /// The framework hands the session to one view for one job; it is used only inside this call.
    private final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ s: TranslationSession) { session = s }
    }

    private nonisolated static func run(_ box: SessionBox, _ texts: [String]) async throws -> [String] {
        let answers = try await box.session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
        return answers.map(\.targetText)
    }

    /// Called from the view's `translationTask` with the session the system made.
    func serve(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        timeout?.cancel()
        do {
            let out = try await Self.run(SessionBox(session), job.texts)
            job.continuation.resume(returning: out)
        } catch {
            job.continuation.resume(throwing: error)
        }
        // A newer job may have been asked for while this one ran (the song changed): its configuration must stay for the view to serve it.
        if pending == nil { configuration = nil }
    }
}
#endif

enum MusicAppleTranslation {
    /// True when this system can translate on the device at all.
    static var isSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, iOS 18.0, *) { return true }
        #endif
        return false
    }
}
