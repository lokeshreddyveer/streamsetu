import AtlasScanCore
import Foundation

// atlas-scan [--repo DIR] [--only PATH_PREFIX] [--strict] [--list] [--accept-exemptions] [--exemptions FILE] [FILE.swift ...]
// --ios scans only ios/StreamSetu against exemptions-ios.json (its own baseline); the default run covers everything and merges both exemption files.
// --json prints the unmarked controls with the offset where a marker can be appended.
// Default mode only reports (exit 0). --strict exits 1 on any unmarked control, short exemption reason or exemption growth.
struct Args {
    var list = Array(CommandLine.arguments.dropFirst())
    mutating func flag(_ n: String) -> Bool { if let i = list.firstIndex(of: n) { list.remove(at: i); return true }; return false }
    mutating func value(_ n: String) -> String? { if let i = list.firstIndex(of: n), i + 1 < list.count { let v = list[i + 1]; list.removeSubrange(i...(i + 1)); return v }; return nil }
}
var a = Args()

let only = a.value("--only")
let strict = a.flag("--strict"), list = a.flag("--list"), accept = a.flag("--accept-exemptions"), iosOnly = a.flag("--ios"), json = a.flag("--json")
let toolDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repo = URL(fileURLWithPath: a.value("--repo") ?? toolDir.deletingLastPathComponent().deletingLastPathComponent().path)
let exOverride = a.value("--exemptions")
let macExURL = URL(fileURLWithPath: exOverride ?? toolDir.appendingPathComponent("exemptions.json").path)
let iosExURL = toolDir.appendingPathComponent("exemptions-ios.json")

let files: [URL] = a.list.isEmpty ? (iosOnly ? Runner.iosRoots : Runner.defaultRoots).flatMap { Runner.swiftFiles(under: repo.appendingPathComponent($0)) } : a.list.map { URL(fileURLWithPath: $0) }
do {
    // Two baselines: Mac rows in exemptions.json, iOS rows (file starts with ios/) in exemptions-ios.json.
    let macEx = try ExemptionFile.load(macExURL), iosEx = try ExemptionFile.load(iosExURL)
    var ex = iosOnly ? iosEx : ExemptionFile(approvedCount: macEx.approvedCount + iosEx.approvedCount, exemptions: macEx.exemptions + iosEx.exemptions)
    var (hits, n) = Runner.scan(repo: repo, files: files)
    // --only: judge just the files under a path prefix (the Mac folders that are finished); exemptions of other files are left out of the check.
    if let only { hits = hits.filter { $0.file.hasPrefix(only) }; ex.exemptions = ex.exemptions.filter { $0.file.hasPrefix(only) }; ex.approvedCount = ex.exemptions.count }
    let report = Report.evaluate(hits: hits, exemptions: ex, files: n)
    if json {
        let rows = report.violations.sorted { ($0.file, $0.line) < ($1.file, $1.line) }.map { ["file": $0.file, "line": $0.line, "construct": $0.construct, "symbol": $0.symbol, "kind": $0.kind.rawValue, "end": $0.chainEnd] as [String: Any] }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
        exit(0)
    }
    print(report.render(listViolations: list || strict), terminator: "")
    if accept {
        ex.approvedCount = ex.exemptions.count
        if iosOnly { try ex.save(iosExURL) }
        else {
            let m = ExemptionFile(approvedCount: macEx.exemptions.count, exemptions: macEx.exemptions), i = ExemptionFile(approvedCount: iosEx.exemptions.count, exemptions: iosEx.exemptions)
            try m.save(macExURL); try i.save(iosExURL)
        }
        print("exemptions accepted at \(ex.approvedCount)")
    }
    let problems = report.problems(acceptingExemptions: accept)
    for p in problems { print((strict ? "error: " : "warning: ") + p) }
    exit(strict && !problems.isEmpty ? 1 : 0)
} catch {
    print("atlas-scan failed: \(error)")
    exit(2)
}
