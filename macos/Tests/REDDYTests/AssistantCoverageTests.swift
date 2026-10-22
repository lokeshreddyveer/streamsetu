import Testing
import Foundation
@testable import REDDY

/// Reads the app's own source to list what exists, and fails when something has no row in the assistant coverage matrix (or a row describes something that is gone).
@MainActor @Suite("Assistant: coverage of the whole app") struct AssistantCoverageTests {
    private static var sources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY") }
    private func text(_ rel: String) throws -> String { try String(contentsOf: Self.sources.appendingPathComponent(rel), encoding: .utf8) }

    /// The case names of `enum Name`, read from its source file.
    private func cases(of name: String, in file: String) throws -> [String] {
        let src = try text(file)
        guard let start = src.range(of: "enum \(name)") else { return [] }
        var out: [String] = [], depth = 0, began = false
        for line in src[start.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if line.contains("{") { began = true }
            let t = line.trimmingCharacters(in: .whitespaces)
            if depth == 1, t.hasPrefix("case ") {
                let bare = t.dropFirst(5).replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                for piece in bare.split(separator: ",") {
                    if let m = piece.range(of: #"^\s*\w+"#, options: .regularExpression) { out.append(String(piece[m]).trimmingCharacters(in: .whitespaces)) }
                }
            }
            if began, depth == 0 { break }
        }
        return out
    }

    @Test func everyStoredSettingIsListed() throws {
        let src = try text("Application/AppSettings.swift")
        let found = Set(src.matches(of: /(?m)^\s{4}var (\w+): [^\n{]*\{ didSet/).map { String($0.1) })
        #expect(found.count > 40, "the source was read")
        let listed = Set(AssistantCoverage.settingKeys.keys).union(AssistantCoverage.settingKeysNotOffered.keys)
        #expect(found.subtracting(listed).isEmpty, "settings with no row: \(found.subtracting(listed).sorted())")
        #expect(listed.subtracting(found).isEmpty, "rows for settings that no longer exist: \(listed.subtracting(found).sorted())")
        #expect(Set(AssistantCoverage.settingKeys.keys).isDisjoint(with: AssistantCoverage.settingKeysNotOffered.keys))
    }

    @Test func everyCatalogueTargetExistsAndNothingIsOrphaned() {
        for (key, target) in AssistantCoverage.settingKeys { #expect(AppSettingsCatalog.find(target ?? key) != nil, "“\(key)” points at a catalogue entry that does not exist") }
        let reached = Set(AssistantCoverage.settingKeys.map { $0.value ?? $0.key })
        // entries that explain a feature (a group of settings) rather than one property
        let groups: Set<String> = ["parental", "profiles", "keywordAlerts", "tmdb", "castReading", "integrations", "recordings", "downloads", "subscriptions", "maintenance"]
        for e in AppSettingsCatalog.all where !reached.contains(e.id) && !groups.contains(e.id) { Issue.record("catalogue entry “\(e.id)” belongs to no stored setting and is not a declared group") }
    }

    @Test func everyTabShortcutModalAndSettingsTabIsListed() throws {
        let tabs = Set(try cases(of: "AppTab", in: "Application/AppRouter.swift")); #expect(tabs == Set(AssistantCoverage.tabs.keys), "tabs: \(tabs.symmetricDifference(Set(AssistantCoverage.tabs.keys)).sorted())")
        let sc = Set(try cases(of: "Shortcut", in: "Application/AppRouter.swift")); #expect(sc == Set(AssistantCoverage.shortcuts.keys), "shortcuts: \(sc.symmetricDifference(Set(AssistantCoverage.shortcuts.keys)).sorted())")
        let mo = Set(try cases(of: "ModalRoute", in: "Application/AppRouter.swift")); #expect(mo == Set(AssistantCoverage.modals.keys), "modals: \(mo.symmetricDifference(Set(AssistantCoverage.modals.keys)).sorted())")
        let st = Set(try cases(of: "SettingsTab", in: "Features/Settings/Views/SettingsView.swift")); #expect(st == Set(AssistantCoverage.settingsTabs.keys), "settings tabs: \(st.symmetricDifference(Set(AssistantCoverage.settingsTabs.keys)).sorted())")
        for (k, v) in AssistantCoverage.shortcuts where v == nil { #expect(AssistantCoverage.shortcutsNotOffered[k] != nil, "an unsupported shortcut needs a reason: \(k)") }
        #expect(!tabs.isEmpty && !sc.isEmpty && !mo.isEmpty && !st.isEmpty, "the source was read")
    }

    @Test func everyFeatureFolderAndContextMenuIsListed() throws {
        let folders = Set(try FileManager.default.contentsOfDirectory(atPath: Self.sources.appendingPathComponent("Features").path).filter { !$0.hasPrefix(".") })
        #expect(folders == Set(AssistantCoverage.features.keys), "feature folders: \(folders.symmetricDifference(Set(AssistantCoverage.features.keys)).sorted())")
        var withMenus = Set<String>()
        let e = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let next = e?.nextObject() {
            guard let u = next as? URL, u.pathExtension == "swift" else { continue }
            if let t = try? String(contentsOf: u, encoding: .utf8), t.contains(".contextMenu") || t.contains("contextMenu(") { withMenus.insert(u.path.replacingOccurrences(of: Self.sources.path + "/", with: "")) }
        }
        #expect(withMenus == Set(AssistantCoverage.contextMenus.keys), "context menus: \(withMenus.symmetricDifference(Set(AssistantCoverage.contextMenus.keys)).sorted())")
    }

    @Test func everyToolAndActionKindIsListed() throws {
        let c = try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("reddy-cov-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
        let tools = Set(AssistantToolbox(container: c).specs(compact: false).map(\.name))
        #expect(tools == Set(AssistantCoverage.tools.keys), "tools: \(tools.symmetricDifference(Set(AssistantCoverage.tools.keys)).sorted())")
        let kinds = Set(try cases(of: "Kind", in: "Services/AssistantAgent.swift"))
        let sampled = Set(AssistantCoverage.sampleKinds().map { String(describing: $0).prefix { $0 != "(" }.description })
        #expect(kinds.subtracting(sampled).isEmpty, "action kinds with no sample row: \(kinds.subtracting(sampled).sorted())")
        let commands = Set(try cases(of: "Kind", in: "Services/SearchCommands.swift"))
        let sampledCommands = Set(AssistantCoverage.sampleKinds().compactMap { k -> String? in if case .command(let c) = k { return String(describing: c.kind).prefix { $0 != "(" }.description } else { return nil } })
        #expect(commands.subtracting(sampledCommands).isEmpty, "command kinds with no sample row: \(commands.subtracting(sampledCommands).sorted())")
    }

    @Test func theRegistryIsConsistent() {
        let specs = AssistantCoverage.sampleKinds().map { AssistantActions.spec(for: $0) }
        #expect(Set(specs.map(\.id)).count == Set(specs.map(\.id)).count)
        for s in specs {
            if s.permission == .bulkOrDestructive || s.permission == .dataDestination { #expect(s.confirmation != nil, "\(s.id) changes a lot: it needs a preview and confirmation") }
            #expect(!s.service.isEmpty && !s.platforms.isEmpty, "\(s.id) names its service and platforms")
            #expect(!s.platforms.contains(.android) && !s.platforms.contains(.fireTV), "\(s.id): Android and Fire TV are not claimed until built and checked")
        }
        #expect(AssistantCoverage.rows().allSatisfy { !$0.key.isEmpty && !$0.area.isEmpty })
        #expect(AssistantCoverage.rows().filter { !$0.isCovered }.allSatisfy { !($0.unsupported ?? "").isEmpty }, "every unsupported row says why")
    }

    @Test func theMatrixCanBeWrittenToDisk() throws {
        let md = AssistantCoverage.markdown()
        #expect(md.contains("Reported, pending independent verification")); #expect(md.contains("| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |"))
        if let path = ProcessInfo.processInfo.environment["ASSISTANT_COVERAGE_WRITE"] { try md.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

@MainActor @Suite("Assistant: action authorization") struct AssistantAuthorizationTests {
    private func situation(_ f: (inout AssistantSituation) -> Void = { _ in }) -> AssistantSituation {
        var s = AssistantSituation(activeProfileID: "me", isKids: false, restricting: false, isLocked: { _ in false }, hasPlayback: true, playbackKey: "item-1", itemExists: { _ in true }, mpvAvailable: true)
        f(&s); return s
    }
    private func proposal(_ k: AssistantProposal.Kind, _ f: (inout AssistantProposal.Origin) -> Void = { _ in }) -> AssistantProposal {
        var o = AssistantProposal.Origin(profileID: "me", createdAt: Date(), playbackKey: "item-1", targetItemID: nil, categoryID: nil); f(&o)
        return AssistantProposal(kind: k, origin: o)
    }

    @Test func anOrdinaryActionIsAllowed() {
        #expect(AssistantAuthorizer.decide(proposal(.playback("pause")), situation()) == .allow)
        #expect(AssistantAuthorizer.decide(proposal(.setting(id: "subtitlesByDefault", value: "on")), situation()) == .allow)
    }
    @Test func aKidsProfileNeverRunsAnything() {
        for k in AssistantCoverage.sampleKinds() { if case .deny = AssistantAuthorizer.decide(proposal(k), situation { $0.isKids = true }) {} else { Issue.record("\(k) must be refused in a kids profile") } }
    }
    @Test func aProfileSwitchCancelsWhatWasOffered() {
        if case .deny(let why) = AssistantAuthorizer.decide(proposal(.refresh) { $0.profileID = "someone-else" }, situation()) { #expect(why.contains("profile changed")) } else { Issue.record("a stale profile must be refused") }
    }
    @Test func oldSuggestionsExpire() {
        var s = situation(); s.now = Date().addingTimeInterval(AssistantAuthorizer.lifetime + 60)
        if case .deny(let why) = AssistantAuthorizer.decide(proposal(.refresh), s) { #expect(why.contains("out of date")) } else { Issue.record("an old suggestion must be refused") }
    }
    @Test func playbackActionsNeedTheSameStreamStillPlaying() {
        for k in [AssistantProposal.Kind.playback("pause"), .retry, .engine("avPlayer"), .track(audio: true, id: nil, label: "x")] {
            if case .deny = AssistantAuthorizer.decide(proposal(k), situation { $0.hasPlayback = false }) {} else { Issue.record("\(k): nothing playing must be refused") }
            if case .deny = AssistantAuthorizer.decide(proposal(k), situation { $0.playbackKey = "a-different-item" }) {} else { Issue.record("\(k): a different stream must be refused") }
        }
    }
    @Test func aTitleInAFolderLockedSinceIsRefusedOnlyWhileFoldersAreHidden() {
        let p = proposal(.command(.init(kind: .play("x")))) { $0.categoryID = "cat-1"; $0.targetItemID = "m1" }
        if case .deny(let why) = AssistantAuthorizer.decide(p, situation { $0.restricting = true; $0.isLocked = { $0 == "cat-1" } }) { #expect(why.contains("locked folder")) } else { Issue.record("locked folder while restricting must be refused") }
        #expect(AssistantAuthorizer.decide(p, situation { $0.restricting = false; $0.isLocked = { $0 == "cat-1" } }) == .allow, "unlocked for now")
        #expect(AssistantAuthorizer.decide(p, situation { $0.restricting = true; $0.isLocked = { _ in false } }) == .allow, "a folder that is not locked")
    }
    @Test func aTitleThatIsGoneIsRefused() {
        let p = proposal(.command(.init(kind: .favourite("x", on: true)))) { $0.targetItemID = "gone" }
        if case .deny = AssistantAuthorizer.decide(p, situation { $0.itemExists = { _ in false } }) {} else { Issue.record("a removed title must be refused") }
    }
    @Test func aSettingIsRevalidatedWhenTapped() {
        if case .deny = AssistantAuthorizer.decide(proposal(.setting(id: "appLock", value: "off")), situation()) {} else { Issue.record("app lock is never changeable") }
        if case .deny = AssistantAuthorizer.decide(proposal(.setting(id: "theme", value: "Rainbow")), situation()) {} else { Issue.record("an invalid value is refused") }
        if case .deny = AssistantAuthorizer.decide(proposal(.setting(id: "nonexistent", value: "on")), situation()) {} else { Issue.record("an unknown setting is refused") }
    }
    @Test func mpvIsOnlyOfferedWhereItExists() {
        if case .deny = AssistantAuthorizer.decide(proposal(.engine("mpv")), situation { $0.mpvAvailable = false }) {} else { Issue.record("MPV must be refused where it is missing") }
    }
    @Test func bigChangesShowAPreviewAndNeedAConfirmation() {
        AssistantAuthorizer.extraConfirmation = { _ in "This will change 12 things." }
        defer { AssistantAuthorizer.extraConfirmation = nil }
        var p = proposal(.refresh)
        #expect(AssistantAuthorizer.decide(p, situation()) == .confirm(preview: "This will change 12 things."))
        p.confirmed = true
        #expect(AssistantAuthorizer.decide(p, situation()) == .allow)
        // confirming does not skip the other checks
        if case .deny = AssistantAuthorizer.decide(p, situation { $0.isKids = true }) {} else { Issue.record("a confirmed action is still refused in a kids profile") }
    }
}
