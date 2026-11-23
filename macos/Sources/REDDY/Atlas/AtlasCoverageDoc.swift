import Foundation

/// docs/assistant-coverage.md, written from the atlas. A test regenerates it and compares, so the document cannot drift from what Setu knows.
enum AtlasCoverageDoc {
    static func reach(_ r: AtlasReach) -> String {
        switch r {
        case .tab(let s): "tab \(s)"
        case .shortcut(let s): "sidebar \(s)"
        case .destination(let s): "destination \(s)"
        case .modal(let s): "modal \(s)"
        case .settingsPage(let s): "settings page \(s)"
        case .window(let s): "window \(s)"
        case .deepLink(let s): "link \(s)"
        case .searchCommand(let s): "search \(s)"
        case .none: "explained only"
        }
    }

    static func platforms(_ p: AtlasPlatforms) -> String {
        var out: [String] = []
        if p.contains(.mac) { out.append("Mac") }
        if p.contains(.iPhone) { out.append("iPhone") }
        if p.contains(.iPad) { out.append("iPad") }
        if p.contains(.dmgOnly) { out.append("direct download only") }
        return out.isEmpty ? "none" : out.joined(separator: ", ")
    }

    private static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }

    static let kindNames: [(AtlasKind, String)] = [
        (.screen, "Screens"), (.settingsPage, "Settings pages"), (.control, "Controls and settings groups"), (.setting, "Settings"), (.menuItem, "Menu commands"), (.shortcut, "Keyboard shortcuts"),
        (.contextAction, "Context menus"), (.gesture, "Gestures and long presses"), (.intent, "Siri and Shortcuts"), (.recipe, "How-tos"), (.diagnosis, "Troubleshooting"), (.meta, "About Setu and what is new"),
    ]

    /// Provider names are scrubbed from the written document (it is prose outside Settings): the same mapping as Scripts/checks/provider_terms.json (a test compares the two).
    static let neutralTerms: [(name: String, word: String)] = [
        ("The Movie Database", "the movie database service"), ("fanart.tv", "the artwork service"), ("TheTVDB", "the series database"), ("TVmaze", "the schedule service"), ("TMDB", "the movie database"),
        ("Netflix", "the external service"), ("Prime Video", "the external service"), ("Disney+", "the external service"), ("Hulu", "the external service"), ("HBO Max", "the external service"),
        ("Peacock", "the external service"), ("Paramount+", "the external service"), ("Apple TV", "the external service"), ("YouTube", "the external service"), ("Crunchyroll", "the external service"),
    ]
    static func scrubbed(_ text: String) -> String {
        var t = text
        for (name, word) in neutralTerms.sorted(by: { $0.name.count > $1.name.count }) {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9])"
            t = t.replacingOccurrences(of: pattern, with: word, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }

    static func markdown(entries: [AtlasEntry], actionMatrix: String) -> String { scrubbed(rawMarkdown(entries: entries, actionMatrix: actionMatrix)) }

    private static func rawMarkdown(entries: [AtlasEntry], actionMatrix: String) -> String {
        var t = "# Assistant coverage\n\nGenerated from the atlas by `AtlasCoverageTests` (set `ATLAS_DOCS_WRITE=1` to rewrite it). Everything Setu can answer about the app is one entry in `macos/Sources/REDDY/Atlas`; this page lists them all. "
        t += "*Reviewed* means the wording was checked against the code by a person or in a test; the rest was written from the code and has not had a second look. Setu answers from these entries with no language model.\n\n"
        t += "## Totals\n\n| Kind | Entries | Reviewed | Mac | iPhone | iPad |\n|---|---|---|---|---|---|\n"
        for (k, name) in kindNames {
            let s = entries.filter { $0.kind == k }
            guard !s.isEmpty else { continue }
            t += "| \(name) | \(s.count) | \(s.filter(\.reviewed).count) | \(s.filter { $0.platforms.contains(.mac) }.count) | \(s.filter { $0.platforms.contains(.iPhone) }.count) | \(s.filter { $0.platforms.contains(.iPad) }.count) |\n"
        }
        t += "| **All** | **\(entries.count)** | **\(entries.filter(\.reviewed).count)** | \(entries.filter { $0.platforms.contains(.mac) }.count) | \(entries.filter { $0.platforms.contains(.iPhone) }.count) | \(entries.filter { $0.platforms.contains(.iPad) }.count) |\n\n"
        t += "Entries Setu explains but never changes (app lock, proxy, parental controls and similar): \(entries.filter(\.guideOnly).count).\n"
        for (k, name) in kindNames {
            let s = entries.filter { $0.kind == k }.sorted { $0.id < $1.id }
            guard !s.isEmpty else { continue }
            t += "\n## \(name)\n\n| Id | Title | Where | Opens | Platforms | Reviewed |\n|---|---|---|---|---|---|\n"
            for e in s {
                t += "| \(cell(e.id)) | \(cell(e.title)) | \(cell(e.path.joined(separator: " > "))) | \(cell(reach(e.reach))) | \(platforms(e.platforms)) | \(e.reviewed ? "yes" : "no") |\n"
            }
        }
        t += "\n---\n\n" + actionMatrix.replacingOccurrences(of: "# Assistant coverage matrix", with: "# What Setu can do for you (actions)").replacingOccurrences(of: "\n## ", with: "\n### ")
        return t
    }
}
