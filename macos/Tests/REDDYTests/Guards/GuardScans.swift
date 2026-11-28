import Foundation

/// The scans behind the guard tests, kept apart from the tests so they depend on nothing but the source files.
enum GuardScans {
    /// file -> number of Groups that can be empty and carry a task or onAppear.
    static func emptyGroupsWithLoadingWork() -> [String: Int] {
        var found: [String: Int] = [:]
        for f in GuardScanner.files() {
            let code = Array(f.code.utf8)
            let openers = (try? NSRegularExpression(pattern: #"\bGroup\s*\{"#))?.matches(in: f.code, range: NSRange(location: 0, length: f.code.utf16.count)) ?? []
            for m in openers {
                // NSRegularExpression offsets are UTF-16; the scan works on UTF-8 bytes, so convert through the string index.
                guard let r = Range(m.range, in: f.code) else { continue }
                let open = f.code.utf8.distance(from: f.code.utf8.startIndex, to: r.upperBound) - 1
                guard open >= 0, open < code.count, code[open] == 123, let close = GuardScanner.matchingBrace(code, open: open) else { continue }
                guard !GuardScanner.modifierChain(code, after: close).filter({ $0 == "task" || $0 == "onAppear" }).isEmpty else { continue }
                if canBeEmpty(GuardScanner.topLevelText(code, open: open, close: close)) { found[f.path, default: 0] += 1 }
            }
        }
        return found
    }

    /// Only `if` statements at the top, none with an `else`: the Group has no view while every condition is false.
    static func canBeEmpty(_ top: String) -> Bool {
        let lines = top.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { ($0.hasPrefix("if ") || $0.hasPrefix("if\t")) && !$0.contains("else") }
    }


    /// file -> task-group children that await a task's value or create an unstructured task.
    static func taskGroupChildrenAwaitingTasks() -> [String: Int] {
        var found: [String: Int] = [:]
        let childPattern = try? NSRegularExpression(pattern: #"\.addTask\w*\s*(\([^)]*\))?\s*\{"#)
        let badPattern = try? NSRegularExpression(pattern: #"\bawait\b[^\n]*\.value\b|\bTask\s*\.detached\b|\bTask\s*(\([^)]*\))?\s*\{"#)
        for f in GuardScanner.files() where f.code.contains("addTask") {
            let code = Array(f.code.utf8)
            for m in childPattern?.matches(in: f.code, range: NSRange(location: 0, length: f.code.utf16.count)) ?? [] {
                guard let r = Range(m.range, in: f.code) else { continue }
                let open = f.code.utf8.distance(from: f.code.utf8.startIndex, to: r.upperBound) - 1
                guard open >= 0, open < code.count, code[open] == 123, let close = GuardScanner.matchingBrace(code, open: open) else { continue }
                let body = String(decoding: code[open...close], as: UTF8.self)
                if badPattern?.firstMatch(in: body, range: NSRange(location: 0, length: body.utf16.count)) != nil { found[f.path, default: 0] += 1 }
            }
        }
        return found
    }


    /// User-facing text assigned or shown as a bare literal instead of through Localized: a toast, a status notice, a banner or an error line. Returns
    /// file -> number of matching lines. Lines that mention Localized are fine.
    static func unlocalizedStatusStrings(under folders: [String]) -> [String: Int] {
        let pattern = try? NSRegularExpression(pattern: #"Toasts\.shared\.(show|error|success)\(\s*"|showNotice\(\s*"|\b(status|statusText|banner|notice|errorMessage|error|message|note|hint|summary|caption|detail|failure|problem|warning|toast)\s*=\s*(\(?[^"=\n]*\?\s*)?"[^"\n]*[A-Za-z]+ [^"\n]*"|errors\[[^\]\n]+\]\s*=\s*"|\b(rejected|failed):\s*""#)
        var found: [String: Int] = [:]
        for f in GuardScanner.files(under: folders) {
            for line in f.literals.split(separator: "\n", omittingEmptySubsequences: true) where !line.contains("Localized") {
                let s = String(line)
                if pattern?.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil { found[f.path, default: 0] += 1 }
            }
        }
        return found
    }

    /// file -> date displays (`.formatted(.dateTime...)`, `.formatted(date:...)`) with no `timeZone:` in a file that also reads dates at UTC midnight.
    /// A date-only string ("1951-09-12") read in UTC and shown in the local zone is a day early west of Greenwich.
    static func utcDatesShownInLocalTime() -> [String: Int] {
        let utc = try? NSRegularExpression(pattern: #"secondsFromGMT:\s*0|identifier:\s*"(UTC|GMT)"|\.gmt\b"#)
        let shown = try? NSRegularExpression(pattern: #"\.formatted\(\s*(\.dateTime|date:)"#)
        var found: [String: Int] = [:]
        for f in GuardScanner.files() {
            guard utc?.firstMatch(in: f.literals, range: NSRange(location: 0, length: f.literals.utf16.count)) != nil else { continue }
            for line in f.code.split(separator: "\n") where !line.contains("timeZone:") {
                let s = String(line)
                if shown?.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil { found[f.path, default: 0] += 1 }
            }
        }
        return found
    }
}
