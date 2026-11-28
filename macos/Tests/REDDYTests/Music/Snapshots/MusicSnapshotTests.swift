import Testing
import Foundation
import SwiftUI
@testable import REDDY

// Responsive snapshot harness for Music. Opt in with MUSIC_SNAPSHOTS=1 (see Scripts/music-snapshots.sh); otherwise every test here is skipped.
// Each scenario is drawn at every size, checked, and written as PNGs plus one contact sheet. Failures name the scenario and the size.

/// What the checks look at, as plain functions of one render. A returned string is one failure.
@MainActor
enum MusicSnapshotChecks {
    static let hitTargetMinimum: CGFloat = MusicHitTarget.macMinimum

    static func evaluate(_ c: MusicSnapshotCase, size: CGSize, frame: CGSize, result r: MusicSnapshotResult, notes: inout [String]) -> [String] {
        var out: [String] = []
        let tag = "[\(c.rawValue) @ \(MusicSnapshotSizes.label(size))]"
        let win = r.windowFrame
        let inside = win.insetBy(dx: -1, dy: -1)

        // (e) A blank or flat picture.
        if r.stddev < 1.5 || r.distinctColours < 6 {
            out.append("\(tag) the render looks blank (luminance stddev \(String(format: "%.2f", r.stddev)), \(r.distinctColours) distinct colours)")
        }

        // (a) Horizontal overflow: the content asks for more width than the frame gives it.
        if r.fitting.width > frame.width + 0.5 {
            out.append("\(tag) horizontal overflow: the content needs \(Int(r.fitting.width.rounded(.up))) pt but the frame is \(Int(frame.width)) pt wide")
        }

        // (b) The layout class and region widths the shell chooses.
        let cls = MusicLayoutClass.resolve(width: frame.width)
        if !c.isBarOnly && !c.isPanelOnly && !c.isSettingsOverlay {
            let panelOpen = c.wantsPanel
            let g = MusicShellGeometry.resolve(totalWidth: frame.width, sidebarExpanded: true, panelOpen: panelOpen)
            if g.shellClass != cls { out.append("\(tag) the shell class is \(g.shellClass) but MusicLayoutClass.resolve gives \(cls)") }
            if g.contentClass != MusicLayoutClass.resolve(width: g.contentWidth) { out.append("\(tag) the content class \(g.contentClass) does not match its width \(Int(g.contentWidth)) pt") }
            if g.panelInline != (panelOpen && cls == .wide) { out.append("\(tag) the context panel is \(g.panelInline ? "inline" : "an overlay") at class \(cls)") }
            let used = g.navWidth + g.contentWidth + (g.panelInline ? g.panelWidth : 0)
            if abs(used - frame.width) > 0.5 { out.append("\(tag) the regions add up to \(Int(used)) pt, not \(Int(frame.width)) pt") }
            if cls < .expanded, g.navWidth != MusicLayoutGrid.navCompactWidth { out.append("\(tag) the sidebar is \(Int(g.navWidth)) pt wide below 1000 pt") }
            if cls >= .expanded, g.navWidth != MusicLayoutGrid.navExpandedWidth { out.append("\(tag) the sidebar is \(Int(g.navWidth)) pt wide at class \(cls)") }
        }

        // Everything below needs the accessibility tree.
        let visible = r.elements.filter { $0.frame.width > 0 && $0.frame.height > 0 && inside.intersects($0.frame) }
        if !r.elements.contains(where: { !$0.label.isEmpty || $0.isInteractive }) {   // AppKit exposes only the host group to a process with no assistive client
            notes.append("\(tag) WARNING the accessibility tree is empty: key-control, hit-target and overlap checks did not run")
            return out
        }

        // (a, continued) Key controls exist, have a size and are not clipped by the window.
        var required: [(String, (MusicSnapshotAXElement) -> Bool)] = c.barIsAbsent ? [] : [("play or pause", { $0.isInteractive && ["play", "pause"].contains($0.label.lowercased()) })]
        if !c.isBarOnly && !c.isPanelOnly && !c.isSettingsOverlay {
            required.append(("sidebar toggle", { $0.isInteractive && $0.label.lowercased().contains("sidebar") }))
            required.append(("search", { $0.isInteractive && $0.label.lowercased().contains("search music") }))
            if c == .searchResults { required.append(("search field", { $0.role == "AXTextField" || $0.role == "AXSearchField" })) }
        }
        for (name, match) in required {
            guard let e = r.elements.first(where: { match($0) && $0.frame.width > 0 }) else { out.append("\(tag) required control missing: \(name)"); continue }
            if !inside.contains(e.frame) { out.append("\(tag) required control clipped or outside the window: \(name) (\(e.frame.debugDescription) vs window \(win.debugDescription))") }
        }

        // (c) Hit targets of interactive elements that are on screen.
        let small = visible.filter { $0.isTapTarget && ($0.frame.width < hitTargetMinimum - 0.5 || $0.frame.height < hitTargetMinimum - 0.5) }
        if !small.isEmpty {
            let list = small.prefix(6).map { "\"\($0.label)\" \(Int($0.frame.width.rounded()))x\(Int($0.frame.height.rounded()))" }.joined(separator: ", ")
            out.append("\(tag) \(small.count) hit target(s) under \(Int(hitTargetMinimum)) pt: \(list)")
        }

        // (d) Sibling controls in the player bar must not overlap.
        let strip = c.isBarOnly ? win : CGRect(x: win.minX, y: win.minY, width: win.width, height: MusicSnapshotSizes.barStrip)
        var bar = visible.filter { $0.isInteractive && strip.insetBy(dx: -1, dy: -1).contains($0.frame) }
        var seen = Set<String>()
        bar = bar.filter { seen.insert("\($0.role)|\($0.frame.debugDescription)").inserted }
        for i in bar.indices {
            for j in bar.indices where j > i {
                let overlap = bar[i].frame.intersection(bar[j].frame)
                if !overlap.isNull, overlap.width * overlap.height > 4 {
                    out.append("\(tag) player bar controls overlap: \"\(bar[i].label)\" and \"\(bar[j].label)\" (\(Int(overlap.width))x\(Int(overlap.height)) pt)")
                }
            }
        }
        return out
    }
}

/// One run's notes (timings, warnings), appended to report.txt next to the PNGs.
@MainActor
enum MusicSnapshotReport {
    static func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let url = MusicSnapshotRenderer.outputDirectory.appendingPathComponent("report.txt")
        let text = lines.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
        for l in lines { print("[MusicSnapshot] \(l)") }
    }
}

@Suite("MusicSnapshot responsive harness", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MUSIC_SNAPSHOTS"] == "1", "Set MUSIC_SNAPSHOTS=1 to render the Music responsive snapshots (Scripts/music-snapshots.sh)."))
@MainActor struct MusicSnapshotTests {

    @Test("Responsive scenarios at every size", arguments: MusicSnapshotCase.responsive)
    func responsive(_ scenario: MusicSnapshotCase) async throws { try await run(scenario) }

    @Test("Stress scenarios at 1100x760", arguments: MusicSnapshotCase.stress)
    func stress(_ scenario: MusicSnapshotCase) async throws { try await run(scenario) }

    private func run(_ c: MusicSnapshotCase) async throws {
        // MUSIC_SNAPSHOT_ONLY=name1,name2 renders just those scenarios (for a quick look while fixing a page).
        if let only = ProcessInfo.processInfo.environment["MUSIC_SNAPSHOT_ONLY"], !only.split(separator: ",").contains(where: { c.rawValue == String($0) }) { return }
        if c.isGraphScenario { try await MusicSnapshotGraph.seed() }
        let world = try MusicSnapshotWorld()
        defer { world.cleanup() }
        let dir = MusicSnapshotRenderer.outputDirectory
        var cells: [(label: String, image: CGImage, failed: Bool)] = []
        var notes: [String] = []
        for size in c.sizes {
            let frame = c.isBarOnly ? CGSize(width: size.width, height: MusicSnapshotSizes.barHeight) : size
            c.prepare(world)
            let view = c.view(world, size: size)
            let result: MusicSnapshotResult
            do { result = try await MusicSnapshotRenderer.render(view, size: frame, environment: c.environment, settle: c.settle) }
            catch {
                Issue.record(Comment(rawValue: "[\(c.rawValue) @ \(MusicSnapshotSizes.label(size))] the render failed: \(error)"))
                continue
            }
            let name = "\(c.rawValue)_\(MusicSnapshotSizes.label(frame))"
            try? result.png.write(to: dir.appendingPathComponent(name + ".png"))

            // (f) Time budget: logged, never a failure.
            let ms = Int((result.renderSeconds * 1000).rounded())
            let slow = result.renderSeconds > MusicSnapshotSizes.renderBudgetSeconds
            notes.append("[\(c.rawValue) @ \(MusicSnapshotSizes.label(frame))] \(ms) ms\(slow ? "  OVER BUDGET (\(Int(MusicSnapshotSizes.renderBudgetSeconds * 1000)) ms)" : "")")

            let failures = MusicSnapshotChecks.evaluate(c, size: size, frame: frame, result: result, notes: &notes)
            for f in failures { Issue.record(Comment(rawValue: f)) }
            cells.append((label: "\(MusicSnapshotSizes.label(frame))  \(MusicLayoutClass.resolve(width: frame.width))", image: result.image, failed: !failures.isEmpty))
        }
        if let sheet = MusicSnapshotRenderer.contactSheet(title: c.rawValue, cells: cells) {
            try? sheet.write(to: dir.appendingPathComponent("contact_\(c.rawValue).png"))
        }
        MusicSnapshotReport.append(notes)
    }
}
