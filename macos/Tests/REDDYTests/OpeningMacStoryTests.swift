import Foundation
import SwiftUI
import Testing
@testable import REDDY

#if os(macOS)
@Suite("Opening: the Mac story")
struct OpeningMacStoryTests {
    private let count = OpeningIcons.symbols.count
    private let size = CGSize(width: 1200, height: 720)
    private var m: OpeningMacStory.Metrics { OpeningMacStory.Metrics(size: size, count: count) }
    private func group(_ i: Int, _ t: Double) -> OpeningMacStory.Group { OpeningMacStory.group(i, m, halfWidth: 600, t) }

    @Test func theStoryIsAPureFunctionOfTimeOnEveryVariant() {
        for v in OpeningVariant.allCases {
            for ms in stride(from: 0.0, through: Double(v.holdMs), by: 37) { #expect(OpeningMacStory.frame(v, at: ms) == OpeningMacStory.frame(v, at: ms)) }
        }
        #expect(OpeningMacStory.frame(.firstInstall, at: 0).t == 0)
        #expect(OpeningMacStory.frame(.firstInstall, at: Double(OpeningVariant.firstInstall.storyMs)) == .lockup)
        #expect(OpeningMacStory.frame(.standard, at: Double(OpeningVariant.standard.holdMs) * 3) == OpeningMacFrame(t: OpeningMacStory.shortEnd, short: true), "the short opening holds its last frame")
        for ms in [0.0, 300, 900] { #expect(OpeningMacStory.frame(.reducedMotion, at: ms) == .lockup, "Reduce Motion is the finished lockup, still") }
    }

    @Test func theFullStoryFitsItsLengthAndTheShortOneIsItsOwnThing() {
        let v = OpeningVariant.firstInstall
        let at = { (t: Double) in OpeningMacStory.frame(v, at: t / OpeningMacStory.end * Double(v.storyMs)).t }
        #expect(abs(at(3.0) - 3.0) < 1e-9 && abs(at(5.5) - 5.5) < 1e-9)
        #expect(OpeningVariant.firstInstall.durationMs >= 7000, "the full opening is at least seven seconds")
        #expect(Double(OpeningVariant.firstInstall.storyMs) >= Double(OpeningVariant.firstInstall.holdMs) * 1.3, "the icons cross at a calmer pace than the shared timeline")
        // Every ordinary launch gets the short opening: no icons, in real seconds, ending where the variant's story ends.
        let f = OpeningMacStory.frame(.standard, at: 1000)
        #expect(f.short && abs(f.t - 1.0) < 1e-9)
        #expect(OpeningMacStory.shortEnd <= Double(OpeningVariant.standard.holdMs) / 1000 + 1e-9)
        #expect(!OpeningMacStory.frame(.firstInstall, at: 1000).short && !OpeningMacFrame.lockup.short)
    }

    private func shortParts(_ t: Double) -> OpeningMacStory.SymbolParts { OpeningMacStory.parts(OpeningMacFrame(t: t, short: true), m) }

    @Test func theShortOpeningIsTheSymbolItsTurnAndTheNameSlidingOut() {
        let a = shortParts(0), b = shortParts(0.7), c = shortParts(1.4), z = shortParts(OpeningMacStory.shortEnd)
        #expect(a.opacity == 0 && !a.isVisible, "it begins on black")
        #expect(b.opacity > 0.99 && b.reveal == 0 && b.angle > 0 && b.angle < 2 * .pi, "the symbol is in and turning before any of the name shows")
        #expect(c.reveal > 0 && c.reveal < 1, "then the name comes out from behind it")
        #expect(z.opacity == 1 && z.reveal == 1 && abs(z.angle - 2 * .pi) < 1e-9 && z.arcs == 1 && z.triangle == 1 && z.mark == 1 && z.play == 1, "and it rests as the finished lockup")
        var lastAngle = -1.0, lastReveal = -1.0
        for t in stride(from: 0.0, through: OpeningMacStory.shortEnd, by: 1.0 / 60) {
            let p = shortParts(t)
            #expect(p.angle >= lastAngle && p.reveal >= lastReveal, "smooth and one-way")
            lastAngle = p.angle; lastReveal = p.reveal
        }
    }

    @Test func theShortAndFullEndingsAreTheSameLockup() {
        let full = OpeningMacStory.parts(.lockup, m), short = shortParts(OpeningMacStory.shortEnd)
        #expect(full.reveal == short.reveal && full.opacity == short.opacity && full.arcs == short.arcs && full.triangle == short.triangle && full.mark == short.mark && full.play == short.play)
        #expect(abs(sin(full.angle - short.angle / 2)) < 1e-9 || abs(full.angle - short.angle) < 1e-9, "both land on the header's pose")
    }

    @Test func theIconsAreTheTopBarsInItsOrderWithSportsAndShortServices() {
        #expect(OpeningIcons.symbols.map(\.name) == ["Live TV", "Movies", "Series", "Podcasts", "Music", "Sports", "Services", "Library"])
        #expect(OpeningIcons.symbols.prefix(5).map(\.symbol) == ["tv", "film", "rectangle.stack.fill", "mic.fill", "music.note"])
    }

    @Test func everyGroupCrossesTheExactCentreInOrderAndPeaksThere() {
        var last = 0.0
        for i in 0..<count {
            // The moment the group is nearest the centre.
            let best = stride(from: 0.0, through: OpeningMacStory.procession.upperBound, by: 0.002).min { abs(group(i, $0).x) < abs(group(i, $1).x) }!
            #expect(abs(group(i, best).x) < 1.5, "group \(i) reaches the centre")
            #expect(group(i, best).focus > 0.99, "and is fully lit there")
            #expect(best > last, "in the approved order"); last = best
            #expect(group(i, best).alpha > 0.99)
        }
        #expect(last <= OpeningMacStory.procession.upperBound + 1e-9)
    }

    @Test func focusIsContinuousAndOnlyNearTheCentre() {
        for i in 0..<count {
            var prev = group(i, 0).focus
            for t in stride(from: 1.0 / 120, through: OpeningMacStory.procession.upperBound, by: 1.0 / 120) {
                let g = group(i, t)
                #expect(abs(g.focus - prev) < 0.12, "no abrupt change in the glow")
                if abs(g.x) > m.focusRadius { #expect(g.focus == 0) }
                prev = g.focus
            }
        }
        // Never two groups at full glow together.
        for t in stride(from: 0.0, through: 4.25, by: 0.01) { #expect((0..<count).filter { group($0, t).focus > 0.9 }.count <= 1) }
    }

    @Test func theTrackMovesRightToLeftAndKeepsGroupsInOrderAndSpacing() {
        for t in stride(from: 0.0, through: 4.25, by: 0.05) {
            let xs = (0..<count).map { group($0, t).x }
            #expect(zip(xs, xs.dropFirst()).allSatisfy { abs(($1 - $0) - m.gap) < 1e-6 }, "equal spacing, in order")
        }
        #expect(group(0, 2.0).x < group(0, 1.0).x)
    }

    @Test func convergenceOnlyBeginsAfterTheLastGroupHasItsFocus() {
        #expect(OpeningMacStory.converge.lowerBound >= OpeningMacStory.procession.upperBound)
        #expect(OpeningMacStory.convergence(4.25) == 0 && OpeningMacStory.convergence(4.75) == 1)
        #expect(group(count - 1, 4.25).focus > 0.99, "the last group is at the centre when convergence starts")
    }

    @Test func theNamesStayWithTheirIconsAndAreGoneBeforeTheSpin() {
        #expect(OpeningMacStory.nameAlpha(4.2) == 1 && OpeningMacStory.nameAlpha(4.6) == 0)
        #expect(OpeningMacStory.namesFade.upperBound <= OpeningMacStory.spin.lowerBound)
    }

    @Test func theSpinIsOneSharedSmoothTurnThatEndsInTheCanonicalPose() {
        var last = -1.0
        for t in stride(from: OpeningMacStory.spin.lowerBound, through: OpeningMacStory.spin.upperBound, by: 0.01) {
            let s = OpeningMacStory.spin(t, m)
            #expect(s.angle >= last); last = s.angle
        }
        let a = OpeningMacStory.spin(4.75, m), b = OpeningMacStory.spin(5.6, m)
        #expect(a.angle == 0 && abs(b.angle - 2 * .pi) < 1e-9, "a full turn: the arcs land in the header's pose")
        #expect(abs(a.radius - m.ring) < 1e-9)
        #expect(abs(b.radius - EclipseGeometry.radius / EclipseGeometry.canvas * m.symbol) < 1e-9, "the formation closes onto the symbol's ring")
    }

    @Test func theIconsBecomeTheSymbolWithNoRemnants() {
        let start = OpeningMacStory.spin(4.75, m), mid = OpeningMacStory.spin(5.2, m), end = OpeningMacStory.spin(5.6, m)
        #expect(start.iconAlpha == 1 && start.arcs == 0 && start.triangle == 0)
        #expect(mid.iconAlpha > 0 && mid.arcs > 0, "icons and the symbol overlap, so it reads as one becoming the other")
        #expect(end.iconAlpha == 0 && end.arcs == 1 && end.triangle == 1, "all icons gone, the full symbol present")
    }

    @Test func theSymbolsGestureEndsExactlyAtRest() {
        let a = OpeningMacStory.gestureScales(5.6), z = OpeningMacStory.gestureScales(6.15)
        #expect(abs(a.mark - 1) < 1e-9 && abs(a.triangle - 1) < 1e-9 && abs(z.mark - 1) < 1e-9 && abs(z.triangle - 1) < 1e-9)
        #expect(OpeningMacStory.gestureScales(5.9).mark > 1)
    }

    @Test func theWordmarkRevealsMonotonicallyFromBehindTheSymbol() {
        #expect(OpeningMacStory.revealProgress(6.15) == 0 && OpeningMacStory.revealProgress(7.25) == 1)
        var last = 0.0
        for t in stride(from: 6.15, through: 7.25, by: 0.01) { let r = OpeningMacStory.revealProgress(t); #expect(r >= last); last = r }
    }

    @Test func nothingJumpsBetweenFramesAt60Hz() {
        for i in 0..<count {
            var prev = group(i, 0)
            for t in stride(from: 1.0 / 60, through: OpeningMacStory.procession.upperBound, by: 1.0 / 60) {
                let g = group(i, t)
                #expect(abs(g.x - prev.x) < m.gap * 0.1, "icon \(i) at \(t)")
                prev = g
            }
        }
    }

    @Test func onlyOneGroupIsOnStageAtATime() {
        for t in stride(from: 0.0, through: 4.25, by: 0.005) {
            let shown = (0..<count).filter { group($0, t).alpha > 0.5 }
            #expect(shown.count <= 1, "at \(t): more than one group is on stage")
            #expect((0..<count).filter { group($0, t).alpha > 0.05 }.count <= 2, "the next is only just appearing as the last leaves")
        }
        // Each is seen on its own for a while around the centre.
        for i in 0..<count {
            let seenAlone = stride(from: 0.0, through: 4.25, by: 0.01).filter { t in
                group(i, t).alpha > 0.99 && (0..<count).allSatisfy { j in j == i || group(j, t).alpha <= 0.01 }
            }
            #expect(seenAlone.count >= 15, "group \(i) has its own moment")
        }
    }

    @Test func theSlidingDistanceScalesWithTheWindow() {
        for width in [480.0, 800, 1200, 2000] {
            let mm = OpeningMacStory.Metrics(size: CGSize(width: width, height: 720), count: count)
            #expect(mm.side > 0 && mm.gap > width * 0.4 && mm.entry < width / 2)
        }
    }

    @Test func theThemeComesFromTheSavedSettings() throws {
        let d = try #require(UserDefaults(suiteName: "opening-theme-\(UUID().uuidString)"))
        let base = OpeningTheme.read(d)
        d.set(true, forKey: "settings.design2")
        d.set("Amethyst", forKey: "settings.theme")
        let purple = OpeningTheme.read(d)
        #expect(purple.background != base.background || purple.accent != base.accent)
        d.set("Red", forKey: "settings.accent")
        let red = OpeningTheme.read(d)
        #expect(red.accent == AccentChoice.red.color && red.accent != purple.accent)
        d.set("Custom", forKey: "settings.theme"); d.set("Coral", forKey: "settings.accent"); d.set("102030,00FF00,FFFFFF,0.2", forKey: "settings.customtheme")
        #expect(OpeningTheme.read(d).accent == Color(hex: 0x00FF00))
    }

    /// Writes review frames to the folder named by SS_RENDER_OPENING (nothing happens without it): the opening at its scenes, for looking at.
    @MainActor @Test func reviewFramesAreWrittenWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["SS_RENDER_OPENING"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        OpeningIcons.preload()
        let theme = OpeningTheme.read()
        let moments: [(String, Double)] = [("a-enter", 0.3), ("b-first", 0.95), ("c-second", 1.4), ("d-mid", 2.4), ("e-sports", 3.3), ("f-last", 4.2), ("g-converge", 4.5), ("h-spin1", 4.95), ("i-spin2", 5.2),
                                           ("j-spin3", 5.45), ("k-symbol", 5.6), ("l-gesture", 5.85), ("m-reveal1", 6.5), ("n-reveal2", 6.8), ("o-lockup", 7.25),
                                           ("s-1", 0.3), ("s-2", 0.8), ("s-3", 1.3), ("s-4", 1.7), ("s-5", 2.65)]
        for (name, t) in moments {
            let r = ImageRenderer(content: OpeningMacCanvas(theme: theme, icons: OpeningIcons.current, frame: { OpeningMacFrame(t: t, short: name.hasPrefix("s-")) }).frame(width: 1200, height: 720))
            r.scale = 1
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: dir + "/\(name).png")) }
        }
    }
}
#endif
