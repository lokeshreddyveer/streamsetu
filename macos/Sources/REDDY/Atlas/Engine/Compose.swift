import Foundation

enum AtlasDecision: String, Sendable { case confident, ambiguous, weak }

struct AtlasAction: Sendable, Equatable {
    enum Kind: String, Sendable { case openThis, changeIt, showMe, pick }
    let kind: Kind
    let entryID: String
    var value: String?
    var label: String
}

struct AtlasAnswer: Sendable {
    var text: String
    var entryIDs: [String]
    var actions: [AtlasAction]
    var decision: AtlasDecision
    var intent: AtlasIntent
}

/// Step 10: every sentence comes from an entry field or a live value. A template that needs a missing field is skipped, never guessed.
enum Compose {
    static let capabilities = "I can explain any screen, setting, shortcut or fix in StreamSetu, show you where it is, and open it for you."

    static func join(_ path: [String]) -> String { path.joined(separator: " > ") }

    static func compose(intent: AtlasIntent, entry e: AtlasEntry, platform: AtlasPlatforms, current: String?, value: String?) -> AtlasAnswer {
        var text = ""
        var actions: [AtlasAction] = []
        let tap = platform.contains(.mac) ? "click" : "tap"
        func open() { if e.reach != .none { actions.append(AtlasAction(kind: .openThis, entryID: e.id, label: "Open this")) } }
        func change() { if e.mayPropose { actions.append(AtlasAction(kind: .changeIt, entryID: e.id, value: value, label: "Change it")) } }
        func show() { actions.append(AtlasAction(kind: .showMe, entryID: e.id, label: "Show me")) }
        let options = e.value?.options ?? []
        let now = current.map { " You have it set to \($0)." } ?? ""
        let choices = options.isEmpty ? "" : " Choices: \(options.joined(separator: ", "))."
        let where_ = e.path.isEmpty ? "" : " It is in \(join(e.path))."

        switch intent {
        case .whereIs:
            text = e.path.isEmpty ? "\(e.title): \(e.summary)" : "\(e.title) is in \(join(e.path))."
            open(); show()
        case .whatDoes, .whyBroken:
            text = "\(e.title): \(e.summary)" + (e.detail.map { " \($0)" } ?? "") + now + choices + (intent == .whatDoes ? where_ : "")
            open()
        case .shortcutFor:
            if let k = e.shortcut { text = "\(e.title): \(k)." + (e.path.isEmpty ? "" : " Also in \(join(e.path)).") } else {
                text = "\(e.title) has no keyboard shortcut." + where_
            }
            open()
        case .howDoI, .setValue, .whatCanIDoHere, .whatsNew, .list, .chat, .other:
            if let steps = e.recipe, !steps.isEmpty {
                text = e.summary + "\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element.say)" }.joined(separator: "\n")
            } else if e.kind == .setting {
                if e.guideOnly {
                    text = "\(e.title) is something I explain but do not change. \(e.summary)" + (e.path.isEmpty ? "" : " To change it, \(tap) through \(join(e.path)).") + now
                } else if intent == .setValue, let v = value, e.mayPropose {
                    text = "\(e.title) is \(current ?? "not set").\(" Change to \(v)?")"
                } else {
                    text = (e.path.isEmpty ? "" : "Open \(join(e.path)). ") + "\(e.title): \(e.summary)" + choices + now
                }
            } else {
                text = "\(e.title): \(e.summary)" + (e.detail.map { " \($0)" } ?? "") + where_
            }
            open(); change(); show()
        }
        return AtlasAnswer(text: text, entryIDs: [e.id], actions: actions, decision: .confident, intent: intent)
    }

    static func chips(_ entries: [AtlasEntry]) -> [AtlasAction] { entries.map { AtlasAction(kind: .pick, entryID: $0.id, label: $0.title) } }

    /// "Did you mean Playback speed, Sleep timer or Volume?" built from the candidates' own titles.
    static func question(_ top: [AtlasEntry]) -> String {
        let t = top.prefix(3).map(\.title)
        switch t.count {
        case 0: return "Did you mean one of these?"
        case 1: return "Did you mean \(t[0])?"
        default: return "Did you mean " + t.dropLast().joined(separator: ", ") + " or " + t.last! + "?"
        }
    }

    static func ambiguous(_ top: [AtlasEntry], intent: AtlasIntent) -> AtlasAnswer {
        AtlasAnswer(text: question(top), entryIDs: top.map(\.id), actions: chips(top), decision: .ambiguous, intent: intent)
    }

    /// Never a dead end: say what is nearby (with where it lives), offer each as a button, and say what Setu can do. The first topic that has a screen also gets an Open button through the caller.
    static func fallback(_ top: [AtlasEntry], intent: AtlasIntent) -> AtlasAnswer {
        guard !top.isEmpty else {
            return AtlasAnswer(text: "I do not have a topic for that yet, and I would rather say so than guess. " + capabilities + " Try naming the screen, setting or problem, for example subtitles, the TV guide, backup or buffering.", entryIDs: [], actions: [], decision: .weak, intent: intent)
        }
        let near = top.prefix(3).map { e in e.path.isEmpty ? e.title : "\(e.title) (\(join(e.path)))" }.joined(separator: "; ")
        let text = "I do not have an exact answer for that, but these are the closest things I know: " + near + ". Pick one below and I will explain it" + (top.contains { $0.reach != .none } ? " or open it" : "") + ", or tell me a bit more."
        var actions = chips(Array(top.prefix(3)))
        if let first = top.first(where: { $0.reach != .none }) { actions.insert(AtlasAction(kind: .openThis, entryID: first.id, label: "Open this"), at: 0) }
        return AtlasAnswer(text: text, entryIDs: top.map(\.id), actions: actions, decision: .weak, intent: intent)
    }
}
