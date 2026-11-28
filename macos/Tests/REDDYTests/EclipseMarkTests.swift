import Testing
import AppKit
import SwiftUI
@testable import REDDY

@MainActor
@Suite("Eclipse wordmark symbol", .serialized) struct EclipseMarkTests {
    private func makeView() -> (EclipseMarkView, NSWindow) {
        let v = EclipseMarkView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        w.contentView?.addSubview(v)
        return (v, w)
    }

    @Test func geometryIsTheSpecifiedOne() {
        #expect(EclipseGeometry.canvas == 64 && EclipseGeometry.radius == 25 && EclipseGeometry.lineWidth == 4)
        #expect(EclipseGeometry.primary.sweep == 149 && EclipseGeometry.secondary.sweep == 64)
        let gap1 = EclipseGeometry.secondary.start - (EclipseGeometry.primary.start + EclipseGeometry.primary.sweep)
        let gap2 = 360 + EclipseGeometry.primary.start - (EclipseGeometry.secondary.start + EclipseGeometry.secondary.sweep)
        #expect(gap1 != gap2 && gap1 > 0 && gap2 > 0, "the gaps are intentionally unequal")
        let b = EclipseGeometry.play().boundingBox
        #expect(b.minX >= 24 && b.maxX <= 47 && b.minY >= 18 && b.maxY <= 46)
    }

    @Test func oneKeyframeAnimationOfSixSecondsWithAHold() {
        let a = EclipseMotion.animation()
        #expect(a.duration == 6 && a.repeatCount == .infinity)
        #expect(a.keyTimes == [0, 0.25, 1])
        #expect(a.timingFunctions?.count == 2)
        let values = (a.values as? [NSNumber])?.map(\.doubleValue)
        #expect(values == [0, Double.pi * 2, Double.pi * 2])
    }

    @Test func runningTwiceStillMeansOneAnimationAndStoppingRemovesIt() {
        let (v, w) = makeView(); _ = w
        let c = NSColor.systemOrange
        v.apply(accent: c, run: true)
        let first = v.orbit.animation(forKey: EclipseMotion.key)
        #expect(first != nil)
        v.apply(accent: c, run: true)
        #expect(v.orbit.animation(forKey: EclipseMotion.key) === first, "no second animation, the running one is kept")
        #expect(v.orbit.animationKeys()?.count == 1)
        v.apply(accent: c, run: false)
        #expect(!v.isAnimating)
        #expect(v.playShape.animationKeys() == nil && v.primaryArc.animationKeys() == nil, "only the orbit layer ever animates")
    }

    @Test func aNewAccentChangesColoursButNeverTheAnimationOrTheGeometry() {
        let (v, w) = makeView(); _ = w
        v.apply(accent: .systemBlue, run: true)
        let anim = v.orbit.animation(forKey: EclipseMotion.key)
        let path = v.primaryArc.path, layers = v.root.sublayers?.count, orbitLayers = v.orbit.sublayers?.count
        v.apply(accent: .systemPink, run: true)
        #expect(v.orbit.animation(forKey: EclipseMotion.key) === anim)
        #expect(v.primaryArc.path === path && v.root.sublayers?.count == layers && v.orbit.sublayers?.count == orbitLayers)
        #expect(v.primaryArc.strokeColor == NSColor.systemPink.cgColor || v.primaryArc.strokeColor != nil)
    }

    @Test func notInAWindowOrHiddenMeansNoAnimation() {
        let v = EclipseMarkView(frame: .zero)
        v.apply(accent: .systemTeal, run: true)
        #expect(!v.isAnimating, "no window")
        let (v2, w) = makeView(); _ = w
        v2.apply(accent: .systemTeal, run: true)
        #expect(v2.isAnimating)
        v2.isHidden = true
        v2.apply(accent: .systemTeal, run: true)
        #expect(!v2.isAnimating, "hidden")
    }

    @Test func secondArcIsTheAccentAtReducedOpacityForEveryThemeAndAccent() {
        let savedTheme = ThemeStore.current, savedAccent = ThemeStore.state.userAccent
        defer { ThemeStore.current = savedTheme; ThemeStore.state.userAccent = savedAccent }
        var lowest = (ratio: 99.0, who: "")
        for theme in AppTheme.allCases {
            ThemeStore.current = theme
            for choice in AccentChoice.allCases {
                ThemeStore.state.userAccent = choice == .coral ? nil : choice.color
                let ns = NSColor(ColorTokens.accent).usingColorSpace(.sRGB)!
                let (v, w) = makeView(); _ = w
                v.apply(accent: ns, run: false)
                let sec = NSColor(cgColor: v.secondaryArc.strokeColor!)!.usingColorSpace(.sRGB)!
                #expect(abs(sec.alphaComponent - ns.alphaComponent * EclipseGeometry.secondaryOpacity) < 0.001, "\(theme.rawValue)/\(choice.rawValue)")
                #expect(NSColor(cgColor: v.primaryArc.strokeColor!)!.usingColorSpace(.sRGB)! == ns)
                // contrast of the faint arc (composited on the header colour) against the header colour
                let bg = NSColor(ColorTokens.barFill).usingColorSpace(.sRGB)!
                func lin(_ c: CGFloat) -> Double { let d = Double(c); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
                func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
                let a = Double(sec.alphaComponent)
                let r = CGFloat(a) * sec.redComponent + CGFloat(1 - a) * bg.redComponent, g = CGFloat(a) * sec.greenComponent + CGFloat(1 - a) * bg.greenComponent, b = CGFloat(a) * sec.blueComponent + CGFloat(1 - a) * bg.blueComponent
                let l1 = lum(r, g, b), l2 = lum(bg.redComponent, bg.greenComponent, bg.blueComponent)
                let ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
                if ratio < lowest.ratio { lowest = (ratio, "\(theme.rawValue)/\(choice.rawValue)") }
            }
        }
        print("EclipseMark lowest secondary-arc contrast over \(AppTheme.allCases.count) themes x \(AccentChoice.allCases.count) accents: \(String(format: "%.2f", lowest.ratio)):1 at \(lowest.who)")
        #expect(lowest.ratio >= 1.5, "the faint arc must stay visible: \(lowest)")
    }

    @Test func brandWidthIncludesTheSymbol() {
        let text = ceil(("StreamSetu" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .bold)]).width) + 6
        #expect(TabLabelMetrics.brandWidth == text + EclipseLayout.size + EclipseLayout.gap)
    }
}
