import Testing
import Foundation

/// A `.task` or `.onAppear` hung on a `Group` whose only content is an `if` without an `else` never runs while the condition is false: SwiftUI has no
/// view to attach it to. When the condition depends on what the task loads, the page never loads (MusicFilmInfoView and MusicSearchEntitySection were
/// real cases; see the comment in Features/Shared/Views/AIViews.swift). The repair is to hang the work on a view that is always there, such as
/// `Color.clear.frame(height: 0).task { ... }` in a ZStack or VStack beside the conditional content.
///
/// The scan is count based like AlwaysOnAnimationGuardTests: each file lists how many such Groups it may hold. `safe` entries are fine, with the reason;
/// `pending` entries are real offenders still to be repaired (remove the entry when the file is fixed: a lower count than listed fails too).
struct LoadOnEmptyContainerGuardTests {
    static let safe: [String: (Int, String)] = [
        "Features/Settings/Views/PrivacySettingsPage.swift": (1, "the task only reads state for the vault that the same condition needs, so there is nothing to load while the Group is empty"),
    ]

    static let pending: [String: (Int, String)] = [
        "Atlas/UI/AtlasPaletteList.swift": (1, "rows are computed by the task while the Group shows only when rows exist, so the first computation never starts"),
    ]

    @Test func noGroupThatCanBeEmptyCarriesTheLoadingWork() {
        let found = GuardScans.emptyGroupsWithLoadingWork()
        let all = Self.safe.merging(Self.pending) { a, b in (a.0 + b.0, a.1) }
        #expect(GuardScanner.overBudget(found, allowed: all).isEmpty,
                "A task or onAppear sits on a Group that can be empty, so it may never run. Hang it on a view that is always there (Color.clear.frame(height: 0).task { }): \(GuardScanner.overBudget(found, allowed: all))")
        #expect(GuardScanner.staleEntries(found, allowed: all).isEmpty, "Lower or remove these entries: \(GuardScanner.staleEntries(found, allowed: all))")
    }

    @Test func theScannerSeesTheKnownShapes() {
        #expect(GuardScans.canBeEmpty("\n    if model.state == .loaded, let info = model.info \n"))
        #expect(GuardScans.canBeEmpty("\n if a \n if b \n"))
        #expect(!GuardScans.canBeEmpty("\n if a  else \n"))
        #expect(!GuardScans.canBeEmpty("\n switch x \n"))
        #expect(!GuardScans.canBeEmpty("\n content \n"))
    }

    @Test func theScannerFindsAGroupInASnippet() {
        let snippet = "struct V { var body: some View { Group { if ready { Text(\"a\") } }\n .frame(width: 1)\n .task(id: key) { await load() } } }"
        let text = GuardScanner.scrub(snippet, blankStrings: true)
        let range = text.range(of: "Group {")!
        let o = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound) - 1
        let c = GuardScanner.matchingBrace(Array(text.utf8), open: o)
        #expect(c != nil)
        #expect(GuardScanner.modifierChain(Array(text.utf8), after: c!) == ["frame", "task"])
    }
}
