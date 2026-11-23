import Foundation

public struct Report: Sendable {
    public var hits: [Hit] = []
    public var marked: [Hit] = []
    public var documented: [Hit] = []
    public var exempt: [Hit] = []
    public var violations: [Hit] = []
    public var staleExemptions: [Exemption] = []
    public var exemptionFile = ExemptionFile()
    public var files = 0

    public init() {}

    public static func evaluate(hits: [Hit], exemptions: ExemptionFile, files: Int) -> Report {
        var r = Report()
        r.hits = hits; r.files = files; r.exemptionFile = exemptions
        let keys = Set(exemptions.exemptions.map(\.key))
        var used = Set<String>()
        for h in hits {
            let key = "\(h.file)|\(h.symbol)|\(h.kind == .iconOnly ? "iconOnly" : h.construct)"
            if h.kind == .control, h.marker != nil { r.marked.append(h) }
            else if h.kind == .control, h.documented { r.documented.append(h) }
            else if keys.contains(key) { r.exempt.append(h); used.insert(key) }
            else if h.kind == .iconOnly, h.documented { r.documented.append(h) }
            else { r.violations.append(h) }
        }
        r.staleExemptions = exemptions.exemptions.filter { !used.contains($0.key) }
        return r
    }

    /// Problems that fail strict mode.
    public func problems(acceptingExemptions: Bool) -> [String] {
        var p: [String] = []
        if !violations.isEmpty { p.append("\(violations.count) control(s) without an atlas id or exemption") }
        if !exemptionFile.shortReasons.isEmpty { p.append("\(exemptionFile.shortReasons.count) exemption(s) with a reason shorter than 8 characters") }
        if exemptionFile.exemptions.count > exemptionFile.approvedCount && !acceptingExemptions {
            p.append("exemptions grew to \(exemptionFile.exemptions.count) (reviewed size \(exemptionFile.approvedCount)); review them and run with --accept-exemptions")
        }
        return p
    }

    public func folderCounts() -> [(folder: String, controls: Int, covered: Int, unmarked: Int)] {
        var m: [String: (Int, Int, Int)] = [:]
        for h in hits where h.kind == .control { m[h.folder, default: (0, 0, 0)].0 += 1 }
        for h in marked + documented + exempt where h.kind == .control { m[h.folder, default: (0, 0, 0)].1 += 1 }
        for h in violations where h.kind == .control { m[h.folder, default: (0, 0, 0)].2 += 1 }
        return m.map { ($0.key, $0.value.0, $0.value.1, $0.value.2) }.sorted { $0.0 < $1.0 }
    }

    public func render(listViolations: Bool) -> String {
        var s = ""
        if listViolations {
            for v in violations.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
                s += v.kind == .iconOnly
                    ? "\(v.file):\(v.line) icon-only Button has no .accessibilityLabel or .help (\(v.symbol))\n"
                    : "\(v.file):\(v.line) \(v.construct) has no atlas id (add .atlas(\"...\") or add to exemptions.json) [\(v.symbol)]\n"
            }
        }
        s += "atlas-scan: \(files) files, \(hits.filter { $0.kind == .control }.count) controls: \(marked.count) marked, \(documented.count) documented, \(exempt.count) exempt, \(violations.filter { $0.kind == .control }.count) unmarked; \(violations.filter { $0.kind == .iconOnly }.count) icon-only buttons without a label\n"
        s += "exemptions: \(exemptionFile.exemptions.count) (reviewed size \(exemptionFile.approvedCount)), stale \(staleExemptions.count)\n"
        for c in folderCounts() { s += "  \(c.folder.padding(toLength: 34, withPad: " ", startingAt: 0)) controls \(String(c.controls).leftPad(5))  covered \(String(c.covered).leftPad(5))  unmarked \(String(c.unmarked).leftPad(5))\n" }
        return s
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
