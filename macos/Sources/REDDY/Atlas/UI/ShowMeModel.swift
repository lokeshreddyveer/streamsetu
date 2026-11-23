import CoreGraphics
import Foundation

/// One thing Show-me points at.
struct ShowMeStep: Equatable, Sendable {
    var say: String
    /// The marker id of the control (an Atlas entry id), or nil for a step that only talks.
    var anchor: String?
    var reach: AtlasReach
    /// The entry that is opened to get to this step's screen.
    var openEntryID: String?
    var openTitle: String
    /// Setu only points at this; the person changes it.
    var guideOnly: Bool
}

/// What the overlay should draw for the current step, given the frames that are recorded right now.
enum ShowMeResolution: Equatable, Sendable {
    case spotlight(CGRect)
    /// A step with nothing to point at.
    case caption
    /// The control is not on this screen. `canOpen` is true when the Atlas knows a route to its screen.
    case missing(openTitle: String, canOpen: Bool)
    /// The screen was opened on request and the control is still not there: tell the person what to look for.
    case openedButNotFound(lookFor: String)
}

/// The walk through a how-to or a single control. Pure value: no views, no navigation, so every rule is testable.
struct ShowMeSession: Equatable, Sendable {
    let title: String
    let steps: [ShowMeStep]
    private(set) var index = 0
    private(set) var opened: Set<Int> = []

    init?(title: String, steps: [ShowMeStep]) {
        guard !steps.isEmpty else { return nil }
        self.title = title; self.steps = steps
    }

    /// A session for an entry: its recipe steps, or one step pointing at the entry's own control. `lookup` finds the entries that steps point at (to know what is guide-only and what to call a screen).
    static func make(for entry: AtlasEntry, lookup: (String) -> AtlasEntry?) -> ShowMeSession? {
        if let recipe = entry.recipe, !recipe.isEmpty {
            let steps = recipe.map { s -> ShowMeStep in
                let target = s.anchor.flatMap(lookup)
                let reach = s.reach ?? target?.reach ?? entry.reach
                // The screen to open: the control's own entry when it has a route, otherwise the how-to's.
                let open: String? = (target?.reach).map { $0 != .none } == true ? target?.id : (entry.reach != .none ? entry.id : nil)
                return ShowMeStep(say: s.say, anchor: s.anchor, reach: reach, openEntryID: open,
                                  openTitle: target.map(openTitle(for:)) ?? openTitle(for: entry), guideOnly: guide(entry) || (target.map(guide) ?? false))
            }
            return ShowMeSession(title: entry.title, steps: steps)
        }
        let step = ShowMeStep(say: entry.summary, anchor: entry.anchor ?? entry.id, reach: entry.reach, openEntryID: entry.reach == .none ? nil : entry.id,
                              openTitle: openTitle(for: entry), guideOnly: guide(entry))
        return ShowMeSession(title: entry.title, steps: [step])
    }

    static func guide(_ e: AtlasEntry) -> Bool { e.guideOnly || e.safety == .never }

    /// The screen a person has to open first: the page an entry lives on, or the entry itself when it is a screen.
    static func openTitle(for e: AtlasEntry) -> String {
        switch e.kind {
        case .screen, .settingsPage, .menuItem, .recipe: return e.title
        default: return e.path.last ?? e.title
        }
    }

    var current: ShowMeStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }
    var progress: String { "Step \(index + 1) of \(steps.count)" }
    var showsProgress: Bool { steps.count > 1 }

    mutating func next() -> Bool { guard !isLast else { return false }; index += 1; return true }
    mutating func back() -> Bool { guard !isFirst else { return false }; index -= 1; return true }
    /// The person pressed the "open it" button for this step.
    mutating func markOpened() { opened.insert(index) }

    /// Frames below this size are layout noise, not a control.
    static let minimumSide: CGFloat = 4

    func resolve(frames: [String: CGRect]) -> ShowMeResolution {
        let step = current
        guard let anchor = step.anchor else { return .caption }
        if let r = frames[anchor], r.width >= Self.minimumSide, r.height >= Self.minimumSide, r.isFinite { return .spotlight(r) }
        if opened.contains(index) { return .openedButNotFound(lookFor: step.openTitle) }
        return .missing(openTitle: step.openTitle, canOpen: step.openEntryID != nil && step.reach != .none)
    }

    /// What VoiceOver says when a step appears.
    func announcement(_ resolution: ShowMeResolution) -> String {
        var s = showsProgress ? "\(progress). " : ""
        s += current.say
        switch resolution {
        case .missing(let t, let canOpen): s += " I can't find it on this screen. " + (canOpen ? "Open \(t) first." : "Open \(t) and try again.")
        case .openedButNotFound(let t): s += " I opened \(t). Look for it there."
        case .spotlight, .caption: break
        }
        if current.guideOnly { s += " Setu only shows you this one. You change it yourself." }
        return s
    }
}

extension CGRect { var isFinite: Bool { !isNull && !isInfinite && !isEmpty && origin.x.isFinite && origin.y.isFinite } }
