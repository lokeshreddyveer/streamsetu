import XCTest
import SwiftUI
import UIKit
@testable import StreamSetu

/// Opt-in screenshots of Settings > Guide, the TV Guide freshness banner and the reminders list (GUIDE_SHOTS_DIR set), from made-up data, in two themes.
@MainActor final class GuideScreenShots: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["GUIDE_SHOTS_DIR"] ?? (try? String(contentsOfFile: "/tmp/guide-shots-dir.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func model() -> GuideSettingsModel {
        func f(_ k: String, _ l: GuideFreshnessLevel, _ a: Int? = nil) -> GuideFreshness { .init(level: l, key: k, amount: a) }
        return GuideSettingsModel(rows: [
            .init(id: "provider:a", title: "Home playlist", kind: .provider, host: nil, enabled: true, freshness: f("guide.fresh", .fresh, 52), summary: "Guide is up to date.", findings: []),
            .init(id: "user:b", title: "Extra guide", kind: .userXMLTV, host: "example.test", enabled: true, freshness: f("guide.updatedLongAgo", .warning, 3), summary: "The guide was last updated 3 days ago.", findings: []),
            .init(id: "provider:c", title: "Second playlist", kind: .provider, host: nil, enabled: true, freshness: f("guide.empty", .error), summary: "The guide holds no programmes.",
                  findings: [GuideFinding(key: "diag.emptyFile", level: .error, args: [], text: GuideMessages.text["diag.emptyFile"]!)]),
        ], enrichmentEnabled: true)
    }

    func testShots() async throws {
        guard let out = dir else { throw XCTSkip("GUIDE_SHOTS_DIR not set") }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let c = try AppContainer(databasePath: NSTemporaryDirectory() + "guide-shots-\(UUID().uuidString).sqlite", credentials: InMemoryCredentialStore())
        let state = AppState(container: c)
        // A real stale guide in the database, so the banner reads it the way the app does.
        let now = Date().timeIntervalSince1970
        try c.db.write { x in
            try x.execute("INSERT INTO guide_sources(id, kind, name, priority, enabled, refresh_hours, created_at) VALUES('user:b','userXMLTV','Extra guide',20,1,6,?)", [now])
            try x.execute("INSERT INTO guide_diagnostics(guide_source_id, last_attempt, last_success, outcome, programmes_kept) VALUES('user:b', ?, ?, 'ok', 100)", [now - 84 * 3600, now - 84 * 3600])
            try x.execute("INSERT INTO guide_import_state(guide_source_id, import_id, updated_at) VALUES('user:b', 1, ?)", [now - 84 * 3600])
            try x.execute("INSERT INTO guide_programmes(guide_source_id, xmltv_id, start_time, end_time, title, import_id) VALUES('user:b','a', ?, ?, 'Evening', 1)", [now - 3600, now + 30 * 3600])
        }
        for theme in [AppTheme.cinematic, .liquidGlass] {
            c.settings.theme = theme
            let screens: [(String, AnyView)] = [
                ("settings-guide", AnyView(NavigationStack { Form { GuideSourcesSection(previewModel: Self.model()) }.navigationTitle("Subscriptions and Alerts") })),
                ("tv-guide-banner", AnyView(VStack(spacing: 0) { Text("TV Guide").font(.title2.bold()).padding(); GuideFreshnessBanner(); Spacer() })),
                ("reminders", AnyView(NavigationStack { Form { Section { GuideRemindersList() } header: { Text("Guide") } }.navigationTitle("Reminders") })),
            ]
            for (name, view) in screens {
                let root = view.environment(c.settings).environment(state).environment(IOSRouter()).environment(\.container, c).background(ColorTokens.background).preferredColorScheme(.dark)
                let host = UIHostingController(rootView: root)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds; window.windowLevel = .alert + 100; window.backgroundColor = .black
                window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let img = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: "\(out)/\(name)-\(theme.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")).png"))
                window.isHidden = true
            }
        }
    }
}
