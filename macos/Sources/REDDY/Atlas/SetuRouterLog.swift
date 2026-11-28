import Foundation
import OSLog

/// Debug log of how Setu decided: which route a question took, how sure the engine was and its three closest entries, and what Return did in the search box. Uses the app's own logger setup (`os.Logger`,
/// subsystem app.streamsetu.mac, category "setu"); the typed words are marked private so they are redacted in a shared log. Read it with: log stream --predicate 'subsystem == "app.streamsetu.mac" && category == "setu"'.
enum SetuRouterLog {
    private static let logger = Logger(subsystem: "app.streamsetu.mac", category: "setu")

    /// One line per question that reached the engine: the route, the engine's decision and confidence, and the top three entry ids.
    static func decision(text: String, route: AssistantIntent, intent: AtlasIntent, decision: AtlasDecision, confidence: Double, top: [String], outcome: String) {
        let ids = top.prefix(3).joined(separator: ", ")
        logger.debug("route=\(route.rawValue, privacy: .public) intent=\(intent.rawValue, privacy: .public) decision=\(decision.rawValue, privacy: .public) score=\(String(format: "%.2f", confidence), privacy: .public) top3=[\(ids, privacy: .public)] outcome=\(outcome, privacy: .public) text=\(text, privacy: .private)")
    }

    /// What Return did in the top search box.
    static func searchReturn(query: String, mode: String, action: String, kids: Bool) {
        logger.debug("search-return mode=\(mode, privacy: .public) action=\(action, privacy: .public) kids=\(kids, privacy: .public) text=\(query, privacy: .private)")
    }
}
