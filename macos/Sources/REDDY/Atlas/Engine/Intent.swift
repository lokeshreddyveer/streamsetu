import Foundation

enum AtlasIntent: String, Sendable, CaseIterable {
    case setValue = "set-value", whereIs = "where-is", howDoI = "how-do-i", whatDoes = "what-does", whyBroken = "why-broken", shortcutFor = "shortcut-for"
    case whatCanIDoHere = "what-can-i-do-here", whatsNew = "whats-new", list, chat, other
}

/// Step 6: ordered cue rules over the cleaned text. The first rule that matches wins; no model is involved.
enum IntentDetector {
    struct Result: Sendable { let intent: AtlasIntent; let value: String? }

    static func detect(_ raw: String) -> Result {
        let t = " " + Normalise.clean(raw) + " "
        func has(_ cues: [String]) -> Bool { cues.contains { t.contains(" \($0) ") || t.contains(" \($0)") && $0.hasSuffix(" ") } }
        func starts(_ cues: [String]) -> Bool { cues.contains { t.hasPrefix(" \($0) ") } }

        if has(["whats new", "what is new", "what changed", "new in", "new features", "release notes", "new version"]) { return Result(intent: .whatsNew, value: nil) }
        if has(["what can i do here", "what can i do on this", "what can i do in this", "what is this screen", "what can you do", "what can you help with"]) || t == " help " || starts(["help me here", "help me", "help here"]) {
            return Result(intent: .whatCanIDoHere, value: nil)
        }
        if starts(["hi", "hello", "hey", "thanks", "thank you", "good morning", "good evening"]) && t.split(separator: " ").count <= 4 { return Result(intent: .chat, value: nil) }
        if has(["shortcut", "shortcuts", "hotkey", "hotkeys", "keyboard", "key for", "key to", "keys", "⌘", "cmd", "command k"]) { return Result(intent: .shortcutFor, value: nil) }
        // Hinglish and Telugu in Latin letters: the same intents, found by their question words (the topic words are matched as usual).
        if has(["nahi aa raha", "nahi aa rahi", "nahi aa rahe", "nahi chal raha", "nahi chal rahi", "nahi ho raha", "nahi dikh raha", "nahi mil raha", "kaam nahi kar", "ledu", "enduku", "endhuku", "kyun", "kyu", "kyon", "kyu nahi"]) { return Result(intent: .whyBroken, value: nil) }
        if has(["kahan", "kahaan", "kidhar", "ekkada", "kahan hai", "kidhar hai"]) { return Result(intent: .whereIs, value: nil) }
        if has(["kaise", "kese", "kaisay", "kaisey", "ela cheyali", "ela cheyyali", "ela", "cheyali", "cheyyali", "kaise kare", "kaise karu", "kaise karein"]) { return Result(intent: .howDoI, value: nil) }
        if has(["kya hai", "kya hota", "enti", "idi enti", "matlab kya"]) { return Result(intent: .whatDoes, value: nil) }
        if has(["not working", "does not work", "do not work", "no sound", "black screen", "buffering", "stutters", "stuttering", "lags", "freezes", "freezing", "keeps stopping", "keeps freezing", "empty", "wrong", "broken", "error", "fails", "failing", "wont", "will not", "does not play", "stuck", "out of sync"])
            || starts(["why"]) {
            return Result(intent: .whyBroken, value: nil)
        }
        if has(["where is", "where are", "where can i find", "where do i find", "where do i", "which screen", "which menu", "where to find", "where s"]) || starts(["find the", "where"]) { return Result(intent: .whereIs, value: nil) }
        if starts(["what is", "what are", "what does", "what do", "explain", "meaning of", "whats", "what happens", "difference between", "tell me about"]) || has(["what happens if", "difference between", "meaning of"]) {
            return Result(intent: .whatDoes, value: nil)
        }
        if starts(["how do i", "how can i", "how to", "how do you", "how would i", "can i", "i want to", "i need to", "i would like to"]) { return Result(intent: .howDoI, value: nil) }
        if starts(["turn", "switch", "set", "change", "make", "enable", "disable", "stop", "start"]) {
            var v = ["on", "off", "yes", "no", "higher", "lower", "bigger", "smaller", "larger"].first { t.contains(" \($0) ") }
            if v == nil { v = starts(["disable", "stop"]) ? "off" : starts(["enable", "start"]) ? "on" : nil }
            return Result(intent: .setValue, value: v)
        }
        if starts(["list", "show all", "show every", "every"]) { return Result(intent: .list, value: nil) }
        return Result(intent: .other, value: nil)
    }

    /// How well an entry's kind suits what is being asked (1 = fine, below 1 = mismatch, 0.85 is the documented penalty).
    static func kindAffinity(_ intent: AtlasIntent, _ kind: AtlasKind) -> Double {
        switch intent {
        case .shortcutFor: return [.shortcut, .menuItem, .meta].contains(kind) ? 1 : 0.85
        case .whyBroken: return [.recipe, .diagnosis, .setting].contains(kind) ? 1 : 0.85
        case .howDoI, .setValue: return [.setting, .recipe, .control, .menuItem, .screen, .settingsPage].contains(kind) ? 1 : 0.85
        case .whereIs: return [.setting, .screen, .settingsPage, .control, .menuItem].contains(kind) ? 1 : 0.85
        default: return 1
        }
    }
}
