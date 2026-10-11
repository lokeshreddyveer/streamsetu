import Foundation

enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case problem = "Problem", idea = "Idea or feature request"
    var id: String { rawValue }
}

/// A problem report or idea, written as an email to the support address. Nothing is sent by the app itself: the person's own mail
/// app sends it, so they see exactly what goes and can edit or cancel. The optional diagnostics text is already redacted
/// (no logins, tokens or stream addresses).
struct FeedbackMessage: Sendable {
    var kind: FeedbackKind
    var text: String
    var diagnostics: String?

    static let address = LegalText.contactEmail

    var subject: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "StreamSetu \(version): \(kind == .problem ? "Problem report" : "Idea")"
    }

    /// The email body without the diagnostics (they travel as an attachment).
    var body: String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = kind == .problem ? "What went wrong, and what were you doing?" : "What would you like StreamSetu to do?" }
        return s
    }

    /// Everything in one piece, for sharing or copying when no mail app is set up.
    var fullText: String { diagnostics.map { body + "\n\n---\n" + $0 } ?? body }

    /// A mailto link, kept short enough for mail apps. Long text and diagnostics are left out of it.
    var mailtoURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"; c.path = Self.address
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: String(body.prefix(1500)))]
        return c.url
    }
}
