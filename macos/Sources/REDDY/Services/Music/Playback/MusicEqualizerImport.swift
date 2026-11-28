import Foundation

// Reads a text equalizer preset in the common parametric format (one filter per line) and fits it to the seven bands. Example lines:
//   Preamp: -6.2 dB
//   Filter 1: ON PK Fc 105 Hz Gain -2.5 dB Q 0.70
//   Filter 2: ON LSC Fc 105 Hz Gain 5 dB Q 0.70
// Peaking, low-shelf and high-shelf filters are used. Other kinds are listed as skipped. The fit samples the file's curve at the seven band
// centres, so a file with many narrow filters is only approximated, and the result says so.

enum MusicEqualizerImport {
    struct Filter: Equatable, Sendable {
        var kind: MusicEqualizerMath.Kind
        var hz: Double
        var gainDB: Double
        var q: Double
    }

    struct Result: Equatable, Sendable {
        var bands: [Double]
        /// The preamp line of the file, if any. Not applied: the automatic preamp takes care of clipping.
        var filePreampDB: Double?
        var filterCount: Int
        var skippedLines: [String]
        var approximated: Bool
        var maxErrorDB: Double
    }

    enum Failure: Error, Equatable { case tooLarge, noFilters }

    static let maxBytes = 1_048_576
    static let maxFilters = 64
    /// Above this many dB between the file's curve and our fit at any test point the import counts as approximated.
    static let approximationToleranceDB = 1.0

    // MARK: parse

    /// The usable filters and the lines that were skipped (unsupported filter kinds and unreadable lines). OFF filters are ignored without comment.
    static func parse(_ text: String) -> (filters: [Filter], preamp: Double?, skipped: [String]) {
        var filters: [Filter] = []
        var preamp: Double?
        var skipped: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("preamp") {
                let nums = numbers(after: "preamp", in: line)
                if let v = nums.first { preamp = (preamp ?? 0) + v } else { skipped.append(line) }
                continue
            }
            guard lower.hasPrefix("filter") else { skipped.append(line); continue }
            let body = line.drop { $0 != ":" }.dropFirst()
            let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first?.uppercased() else { skipped.append(line); continue }
            if first == "OFF" { continue }
            guard first == "ON", tokens.count > 1 else { skipped.append(line); continue }
            guard let kind = kind(of: tokens[1].uppercased()) else { skipped.append(line); continue }
            func value(_ key: String) -> Double? {
                guard let i = tokens.firstIndex(where: { $0.lowercased() == key }), i + 1 < tokens.count else { return nil }
                return number(tokens[i + 1])
            }
            guard let fc = value("fc"), fc.isFinite, fc > 0 else { skipped.append(line); continue }
            let gain = value("gain") ?? 0
            let q = value("q") ?? 0.707
            filters.append(Filter(kind: kind, hz: min(24_000, max(10, fc)), gainDB: min(24, max(-24, gain.isFinite ? gain : 0)), q: min(50, max(0.05, q.isFinite ? q : 0.707))))
        }
        return (filters, preamp, skipped)
    }

    private static func kind(of code: String) -> MusicEqualizerMath.Kind? {
        switch code {
        case "PK", "PEQ", "PEAK": .bell
        case "LSC", "LS", "LSQ": .lowShelf
        case "HSC", "HS", "HSQ": .highShelf
        default: nil
        }
    }

    private static func number(_ token: String) -> Double? {
        var t = token.trimmingCharacters(in: CharacterSet(charactersIn: "dDbBhHzZ"))
        t = t.replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }

    private static func numbers(after key: String, in line: String) -> [Double] {
        guard let r = line.range(of: key, options: .caseInsensitive) else { return [] }
        let rest = line[r.upperBound...].drop { $0 == ":" || $0 == " " }
        return rest.split(separator: " ").compactMap { number(String($0)) }
    }

    // MARK: fit

    /// Our seven bands for the filters: the file's summed curve read at each band centre, to 0.5 dB, within -12...12.
    static func fit(_ text: String) throws -> Result {
        guard text.utf8.count <= maxBytes else { throw Failure.tooLarge }
        let parsed = parse(text)
        guard !parsed.filters.isEmpty, parsed.filters.count <= maxFilters else { throw Failure.noFilters }
        let secs = parsed.filters.map { MusicEqualizerMath.Section(kind: $0.kind, hz: $0.hz, gainDB: $0.gainDB, q: $0.q) }
        func target(_ hz: Double) -> Double { secs.reduce(0) { $0 + MusicEqualizerMath.magnitudeDB($1, at: hz) } }
        var clamped = false
        let bands: [Double] = MusicEqualizerMath.bandCentres.map { hz in
            let raw = target(hz)
            let v = (raw * 2).rounded() / 2
            let c = min(12, max(-12, v))
            if c != v { clamped = true }
            return c
        }
        var s = MusicEqualizerSettings()
        s.enabled = true
        s.bands = bands
        var worst = 0.0
        var hz = 40.0
        while hz <= 16_000 {
            worst = max(worst, abs(MusicEqualizerMath.responseDB(s, at: hz) - target(hz)))
            hz *= pow(2, 1.0 / 3)
        }
        let approximated = clamped || !parsed.skipped.isEmpty || worst > approximationToleranceDB
        return Result(bands: bands, filePreampDB: parsed.preamp, filterCount: parsed.filters.count, skippedLines: parsed.skipped,
                      approximated: approximated, maxErrorDB: worst)
    }

    /// Reads a file of at most 1 MiB (UTF-8, or Latin-1 when that fails) and fits it.
    static func load(_ url: URL) throws -> Result {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw Failure.noFilters }
        return try fit(text)
    }
}
