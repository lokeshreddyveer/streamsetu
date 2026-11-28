import Foundation
import Testing
@testable import REDDY

@Suite("Music graph navigation: history with page memory") struct NavHistoryTests {
    private func eid(_ kind: MusicEntityKind, _ n: Int) -> MusicEntityID { .provisional(kind: kind, providerUID: "p:\(n)") }
    private func entry(_ stack: [MusicRoute], section: MusicSection = .home) -> MusicNavEntry { MusicNavEntry(section: section, stack: stack) }

    /// The shell's steps in miniature: remember the place being left, observe the new one, hand memory back on a step.
    private struct Shell {
        var history = MusicNavHistory()
        var book = MusicPageMemoryBook()
        var scroll: [String: Double] = [:]

        mutating func leave() {
            let key = history.current.scrollKey
            var m = book.memory(for: key) ?? MusicPageMemory()
            m.scrollOffset = scroll[key] ?? m.scrollOffset
            history.remember(m)
        }
        mutating func go(_ e: MusicNavEntry) {
            leave()
            let change = history.observe(e)
            if change == .steppedBack || change == .steppedForward { restore(history.current) }
        }
        mutating func back() -> MusicNavEntry? { leave(); guard let e = history.back() else { return nil }; restore(e); return e }
        mutating func forward() -> MusicNavEntry? { leave(); guard let e = history.forward() else { return nil }; restore(e); return e }
        mutating func restore(_ e: MusicNavEntry) {
            book.set(e.memory, for: e.scrollKey)
            if let y = e.memory.scrollOffset { scroll[e.scrollKey] = y }
        }
    }

    @Test func backAndForwardRestoreRouteScrollRoleAndFilters() {
        var s = Shell()
        var routes: [MusicRoute] = []
        for i in 0..<10 { routes.append(i % 2 == 0 ? .person(eid(.person, i), role: .singer) : .albumPage(eid(.album, i))) }
        for (i, r) in routes.enumerated() {
            s.go(entry([r]))
            let key = r.scrollKey
            s.scroll[key] = Double(100 * (i + 1))
            s.book.update(key) { $0.filters["sort"] = "year\(i)"; $0.selectedTab = "tab\(i)"; $0.expandedSections = ["credits\(i)"] }
        }
        // walk back to the start, checking each place
        for i in stride(from: 8, through: 0, by: -1) {
            let e = s.back()
            #expect(e?.route == routes[i])
            let key = routes[i].scrollKey
            #expect(s.scroll[key] == Double(100 * (i + 1)))
            #expect(s.book.memory(for: key)?.filters["sort"] == "year\(i)")
            #expect(s.book.memory(for: key)?.selectedTab == "tab\(i)")
            #expect(s.book.memory(for: key)?.expandedSections == ["credits\(i)"])
        }
        // and forward again
        for i in 1...9 {
            let e = s.forward()
            #expect(e?.route == routes[i])
            #expect(s.scroll[routes[i].scrollKey] == Double(100 * (i + 1)))
        }
    }

    @Test func memorySurvivesEvenWhenTheLiveBookForgotIt() {
        var s = Shell()
        let a = MusicRoute.albumPage(eid(.album, 1)), b = MusicRoute.film(eid(.film, 2))
        s.go(entry([a]))
        s.scroll[a.scrollKey] = 420
        s.book.update(a.scrollKey) { $0.filters["role"] = "composer" }
        s.go(entry([a, b]))
        s.book.clear()
        s.scroll = [:]
        _ = s.back()
        #expect(s.scroll[a.scrollKey] == 420)
        #expect(s.book.memory(for: a.scrollKey)?.filters["role"] == "composer")
    }

    @Test func aRepeatOfTheCurrentPlaceIsIgnoredAndKeepsItsMemory() {
        var h = MusicNavHistory()
        let e = entry([.film(eid(.film, 1))])
        #expect(h.observe(e) == .recorded)
        h.remember(MusicPageMemory(scrollOffset: 10))
        #expect(h.observe(e) == .unchanged)
        #expect(h.current.memory.scrollOffset == 10)
        #expect(h.entries.count == 2)
    }

    @Test func theHistoryIsCappedAtAboutAHundred() {
        var h = MusicNavHistory()
        for i in 0..<(MusicNavHistory.capacity + 40) { h.observe(entry([.entity(eid(.recording, i))])) }
        #expect(h.entries.count == MusicNavHistory.capacity)
        #expect(h.current.route == .entity(eid(.recording, MusicNavHistory.capacity + 39)))
    }

    @Test func aCycleThroughTheStackIsAStepBackNotAGrowingHistory() {
        var nav = MusicNav(); var h = MusicNavHistory()
        let a = MusicRoute.albumPage(eid(.album, 1)), b = MusicRoute.person(eid(.person, 2))
        nav.push(a); h.observe(MusicNavEntry(nav))
        nav.push(b); h.observe(MusicNavEntry(nav))
        nav.push(a); #expect(h.observe(MusicNavEntry(nav)) == .steppedBack)
        #expect(h.entries.count == 3)
        #expect(h.canGoForward)
    }

    // MARK: last session

    @Test func theLastSessionRoundTripsWithItsMemory() throws {
        var h = MusicNavHistory()
        let a = MusicRoute.albumPage(eid(.album, 1)), b = MusicRoute.person(eid(.person, 2), role: .singer)
        h.observe(entry([a], section: .library)); h.remember(MusicPageMemory(scrollOffset: 33, filters: ["sort": "year"], selectedTab: "cast"))
        h.observe(entry([a, b], section: .library))
        let data = try JSONEncoder().encode(h.snapshot())
        #expect(data.count < 8_000)
        let back = try #require(MusicNavHistory(snapshot: try JSONDecoder().decode(MusicSessionSnapshot.self, from: data)))
        #expect(back.entries == h.entries)
        #expect(back.index == h.index)
        #expect(back.entries[1].memory.scrollOffset == 33 && back.entries[1].memory.selectedTab == "cast")
        #expect(back.current.route == b)
    }

    @Test func aSavedSessionCutsLegacyValuesAndSkipsSettings() {
        var h = MusicNavHistory()
        let album = MusicAlbum(id: "a", providerID: "p", title: "x")
        h.observe(entry([.albumPage(eid(.album, 1)), .album(album), .film(eid(.film, 2))], section: .library))
        h.observe(entry([], section: .settings))
        let snap = h.snapshot()
        #expect(snap.entries.allSatisfy { $0.section != "settings" })
        #expect(snap.entries.last?.stack.count == 1)
        let restored = MusicNavHistory(snapshot: snap)
        #expect(restored?.current.stack == [.albumPage(eid(.album, 1))])
    }

    @Test func aSessionIsBoundedAndABadOneIsRefused() {
        var h = MusicNavHistory()
        for i in 0..<60 { h.observe(entry([.entity(eid(.recording, i))])) }
        #expect(h.snapshot().entries.count <= MusicSessionSnapshot.maxEntries)
        #expect(MusicNavHistory(snapshot: MusicSessionSnapshot(entries: [], index: 0)) == nil)
        let junk = MusicSessionSnapshot(entries: [.init(section: "nope", stack: ["x"], memory: MusicPageMemory())], index: 0)
        #expect(MusicNavHistory(snapshot: junk) == nil)
        var m = MusicPageMemory(scrollOffset: .nan, filters: Dictionary(uniqueKeysWithValues: (0..<40).map { ("k\($0)", String(repeating: "v", count: 200)) }))
        m = m.bounded()
        #expect(m.scrollOffset == nil && m.filters.count == 12 && m.filters.values.allSatisfy { $0.count <= 64 })
    }

    @Test func pageMemoryBookIsABoundedLRU() {
        var b = MusicPageMemoryBook()
        for i in 0..<(MusicPageMemoryBook.capacity + 10) { b.set(MusicPageMemory(scrollOffset: Double(i + 1)), for: "k\(i)") }
        #expect(b.keys.count == MusicPageMemoryBook.capacity)
        #expect(b.memory(for: "k0") == nil)
        #expect(b.memory(for: "k\(MusicPageMemoryBook.capacity + 9)") != nil)
        b.set(MusicPageMemory(), for: "k20")
        #expect(b.memory(for: "k20") == nil)
    }
}
