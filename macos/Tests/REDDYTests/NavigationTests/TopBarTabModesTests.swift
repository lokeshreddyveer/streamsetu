import Testing
import Foundation
@testable import REDDY

/// Per-item modes for the six native items of the top bar (Icon and Name, Icon Only, Name Only). No item can be hidden. Pure planner, no window.
@Suite("Top bar: native item modes") @MainActor struct TopBarTabModesTests {
    private func state(_ w: CGFloat, modes: TopBarTabModes = TopBarTabModes(), pinned: [ProviderID] = [.netflix, .hulu, .youtube], destination: TopLevelDestination = .streamSetu, podcasts: Bool = true) -> TopBarState {
        var nav = ServicesNavigationBinding(); nav.pinned = pinned; nav.tabModes = modes; nav.podcastsAvailable = podcasts
        if case .service(let s) = destination { nav.active = s }
        return TopBarState(tab: .movies, initials: "LR", accountMenuOpen: false, width: w, destination: destination, services: [], showsServicesMenu: true, servicesNav: nav)
    }
    private func modes(_ m: TabBarMode) -> TopBarTabModes { var t = TopBarTabModes(); NavTab.allCases.forEach { t.set(m, for: $0) }; return t }
    private let widths: [CGFloat] = [1024, 1100, 1180, 1280, 1440, 1728, 2200]

    @Test func defaultIsIconAndNameForAllSixWithTheSymbolsListed() {
        let row = TopBarMenuRow.make(for: state(1728))
        #expect(row.leading.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide", "Podcasts"])
        #expect(row.leading.map(\.glyph) == ["house.fill", "tv", "film", "rectangle.stack.fill", "calendar", "mic.fill"])
        #expect(row.leading.allSatisfy { !$0.compact } && TopBarTabModes().isDefault)
    }

    @Test func eachModeDrawsWhatItSays() {
        let io = TopBarMenuRow.make(for: state(2200, modes: modes(.iconOnly)))
        #expect(io.leading.allSatisfy { $0.compact && $0.glyph != nil && $0.width(tabPadding: io.tabPadding) == ServiceChip.hitWidth })
        let no = TopBarMenuRow.make(for: state(2200, modes: modes(.nameOnly)))
        #expect(no.leading.allSatisfy { !$0.compact && $0.glyph == nil })
    }

    @Test func accessibilityAndTooltipAlwaysCarryTheFullName() {
        for m in TabBarMode.allCases {
            for item in TopBarMenuRow.make(for: state(2200, modes: modes(m))).leading {
                #expect((item.label ?? item.title) == item.title && item.help == item.title, Comment(rawValue: "\(m) \(item.title)"))
            }
        }
    }

    @Test func everyCombinationFitsAtEveryWidthKeepsAllSixAndDegradesFromTheRight() {
        let combos: [[TabBarMode]] = {
            var out: [[TabBarMode]] = [[]]
            for _ in 0..<6 { out = out.flatMap { c in TabBarMode.allCases.map { c + [$0] } } }
            return out
        }()
        #expect(combos.count == 729)
        for w in widths {
            for (n, combo) in combos.enumerated() where n % 7 == 0 || combo.allSatisfy({ $0 == .iconAndName }) || combo.allSatisfy({ $0 == .nameOnly }) {
                var t = TopBarTabModes(); for (i, tab) in NavTab.allCases.enumerated() { t.set(combo[i], for: tab) }
                let row = TopBarMenuRow.make(for: state(w, modes: t, pinned: [.netflix]))
                let budget = row.metrics.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) - 2 * TopBarMetrics.navGroupPadding
                #expect(row.leading.count == 6, "no item is ever hidden")
                let leadW = row.leading.reduce(0) { $0 + $1.width(tabPadding: row.tabPadding) }
                #expect(leadW + row.servicesItem.width(tabPadding: row.tabPadding) <= budget + 0.5, "the native group and Services fit at \(Int(w))")
                // degrade order: once an item had to become icon-only that the person did not ask for, everything to its right is icon-only too
                var degraded = false
                for (i, item) in row.leading.enumerated() {
                    let asked = t.mode(NavTab.allCases[i])
                    if item.compact && asked != .iconOnly { degraded = true }
                    if degraded { #expect(item.compact, "names drop from the right-most item inward") }
                }
                // the left items keep what was asked unless degraded
                for (i, item) in row.leading.enumerated() where !degraded { #expect(item.compact == (t.mode(NavTab.allCases[i]) == .iconOnly)) }
            }
        }
    }

    @Test func atTheNarrowestWindowAllSixFitAsIconsAlongsideTheServicesButtonAndASearchBox() {
        let w: CGFloat = 1024
        let row = TopBarMenuRow.make(for: state(w, modes: modes(.iconOnly), pinned: [.netflix, .hulu, .youtube]))
        #expect(row.leading.count == 6 && row.leading.allSatisfy(\.compact))
        #expect(row.width <= row.metrics.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) + 0.5)
        // no native item is ever lost, however many pins there are (here the names no longer fit, so they drop to icons and the pins wait in the list)
        let crowded = TopBarMenuRow.make(for: state(w, modes: modes(.iconAndName), pinned: [.netflix, .hulu, .youtube, .hbomax, .disneyplus, .primevideo, .appletv]))
        #expect(crowded.leading.count == 6 && crowded.width <= crowded.metrics.centerBudget(width: w, brandWidth: TabLabelMetrics.brandWidth) + 0.5)
        #expect(crowded.pinned.isEmpty && crowded.overflow.count == 7)
    }

    @Test func stateBIsUnchangedByTheModes() {
        let a = TopBarMenuRow.make(for: state(1440, modes: modes(.iconOnly), destination: .service(.hulu)))
        let b = TopBarMenuRow.make(for: state(1440, destination: .service(.hulu)))
        #expect(a == b && a.leading.map(\.title) == ["StreamSetu"])
    }

    @Test func podcastsStaysOutOnlyWhereTheRulesHideIt() {
        let kids = TopBarMenuRow.make(for: state(1440, podcasts: false))
        #expect(kids.leading.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide"])
        #expect(TopBarMenuRow.make(for: state(1440)).leading.last?.title == "Podcasts")
    }

    @Test func choicesAreWrittenOnlyWhenNotDefaultAndMigrateFromNothing() {
        let d = UserDefaults(suiteName: "tabmodes-" + UUID().uuidString)!
        #expect(TopBarTabModes.load(from: d).isDefault && d.object(forKey: TopBarTabModes.defaultsKey) == nil)
        var t = TopBarTabModes(); t.set(.iconOnly, for: .movies); t.set(.iconAndName, for: .home)
        t.save(to: d)
        #expect(TopBarTabModes.load(from: d).mode(.movies) == .iconOnly && TopBarTabModes.load(from: d).mode(.home) == .iconAndName)
        let raw = try? JSONDecoder().decode([String: String].self, from: d.data(forKey: TopBarTabModes.defaultsKey) ?? Data())
        #expect(raw == ["movies": "iconOnly"], "only the non-default choice is stored")
        t.reset(); t.save(to: d)
        #expect(d.object(forKey: TopBarTabModes.defaultsKey) == nil, "no key left when everything is default")
        d.set(Data("junk".utf8), forKey: TopBarTabModes.defaultsKey)
        #expect(TopBarTabModes.load(from: d).isDefault)
        d.set(Data(#"{"movies":"hidden","nope":"iconOnly","series":"nameOnly"}"#.utf8), forKey: TopBarTabModes.defaultsKey)
        let l = TopBarTabModes.load(from: d)
        #expect(l.mode(.movies) == .iconAndName && l.mode(.series) == .nameOnly, "an unknown or removed mode reads as the default")
    }

    @Test func settingsModelSetsAndResetsAndTheServicesListHasNoStreamSetuSection() {
        let d = UserDefaults.standard
        let saved = d.data(forKey: TopBarTabModes.defaultsKey); defer { if let saved { d.set(saved, forKey: TopBarTabModes.defaultsKey) } else { d.removeObject(forKey: TopBarTabModes.defaultsKey) } }
        let m = StreamingServicesSettingsModel()
        m.resetTabModes()
        m.setTabMode(.guide, .iconOnly); m.setTabMode(.podcasts, .nameOnly)
        #expect(TopBarTabModes.load().mode(.guide) == .iconOnly && TopBarTabModes.load().mode(.podcasts) == .nameOnly && !m.tabModes.isDefault)
        m.resetTabModes()
        #expect(TopBarTabModes.load().isDefault && m.tabModes.isDefault)
        var nav = ServicesNavigationBinding(); nav.pinned = [.netflix]
        #expect(ServicesMenuModel(nav: nav).rows(filter: "").allSatisfy { if case .service = $0 { true } else { false } })
        #expect(ServicesMenuModel(nav: nav).rows(filter: "home").isEmpty && ServicesMenuModel(nav: nav).rows(filter: "podcasts").isEmpty)
    }

    @Test func modeTitlesAreTheThreeOffered() {
        #expect(TabBarMode.allCases.map(\.title) == ["Icon and Name", "Icon Only", "Name Only"])
        #expect(NavTab.allCases.count == 6 && NavTab.allCases.map(\.title) == ["Home", "Live TV", "Movies", "Series", "TV Guide", "Podcasts"])
    }
}
