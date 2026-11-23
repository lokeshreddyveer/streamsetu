import Foundation
import Observation

/// The one Show-me in the app. Anything that wants to point at a control calls `start`; the host at the root draws it. Which screen to open is the platform's job (`opener`), so this file knows no router.
@MainActor @Observable final class ShowMeController {
    static let shared = ShowMeController()

    private(set) var session: ShowMeSession?
    /// Bumped on every step or restart, so the overlay can announce and scroll once per step.
    private(set) var tick = 0
    var isActive: Bool { session != nil }

    /// Opens the screen of an entry (the same call the "Open this" button uses). Returns false when it could not. Set by the root view of each platform.
    @ObservationIgnored var opener: ((String) -> Bool)?
    /// Set by `.atlasScrollProxy`: scrolls the marked view into sight.
    @ObservationIgnored var scrollHandler: ((String) -> Void)?
    @ObservationIgnored var lookup: (String) -> AtlasEntry? = { Atlas.entry($0) }

    init() {}

    /// Starts a walk for an entry. False when there is nothing to show (unknown entry).
    @discardableResult func start(entryID: String) -> Bool {
        guard let e = lookup(entryID), let s = ShowMeSession.make(for: e, lookup: lookup) else { return false }
        session = s; tick += 1
        return true
    }

    func start(session s: ShowMeSession) { session = s; tick += 1 }

    func next() { guard session != nil else { return }; if session?.next() == true { tick += 1 } else { finish() } }
    func back() { if session?.back() == true { tick += 1 } }
    func finish() { session = nil; tick += 1 }

    /// The "open it" button in the can't-find-it card. After opening, the overlay looks again; the step then says where to look if the control is still not there.
    func openCurrentScreen() {
        guard let s = session, let id = s.current.openEntryID else { return }
        _ = opener?(id)
        session?.markOpened()
        tick += 1
    }

    func scrollIntoView(_ anchor: String) { scrollHandler?(anchor) }
}
