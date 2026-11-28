import Foundation
import SwiftUI
import AppKit
@testable import REDDY

// Renders a SwiftUI view in an offscreen window at an exact size and returns the picture, the size the content asked for, the accessibility
// elements and the time it took. Nothing here touches the running app: the window lives in this test process, off the visible screen.

/// What a render can vary. Light is the system look of the window only: the app itself ships dark themes.
struct MusicSnapshotEnvironment {
    var theme: AppTheme = .cinematic
    var accentName: String? = "coral"
    var dark = true
    var rightToLeft = false
    var reduceTransparency = false
    var increaseContrast = false
    var textStep: MusicTextStep = .standard
}

struct MusicSnapshotAXElement {
    var role: String
    var label: String
    var frame: CGRect          // screen coordinates, origin bottom-left
    var isInteractive: Bool { ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXSlider"].contains(role) }
    var isTapTarget: Bool { ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton"].contains(role) }
}

struct MusicSnapshotResult {
    var image: CGImage
    var png: Data
    /// What the content needs when offered the frame: wider than the frame means it overflows.
    var fitting: CGSize
    var elements: [MusicSnapshotAXElement]
    var windowFrame: CGRect
    /// Layout, draw and encode only (the settle wait is not in it).
    var renderSeconds: Double
    var stddev: Double
    var distinctColours: Int
}

private struct MusicSnapshotEnvironmentModifier: ViewModifier {
    let env: MusicSnapshotEnvironment
    func body(content: Content) -> some View {
        let a11y = MusicAccessibility(reduceMotion: true, reduceTransparency: env.reduceTransparency, increaseContrast: env.increaseContrast,
                                      differentiateWithoutColor: false, textStep: env.textStep)
        content
            .environment(\.layoutDirection, env.rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.reddyAccent, MusicSnapshotStyle.accent(named: env.accentName) ?? ColorTokens.accentDefault)
            .environment(\.musicA11y, a11y)
            .preferredColorScheme(env.dark ? .dark : .light)
            .font(Typography.body)
            .foregroundStyle(ColorTokens.textPrimary)
            .scrollIndicators(.hidden)
            .transaction { t in t.disablesAnimations = true; t.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ColorTokens.background)
    }
}

@MainActor
enum MusicSnapshotRenderer {
    /// AppKit builds the SwiftUI accessibility tree only for a client that asked for it; the override values are what an assistive client sets.
    static func enableAccessibilityTree() {
        for symbol in ["_AXSApplicationAccessibilitySetEnabled", "_AXSSetAutomationEnabled", "_AXSAutomationEnabled"] {
            if let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, symbol) {
                typealias SetFlag = @convention(c) (Bool) -> Void
                if symbol != "_AXSAutomationEnabled" { unsafeBitCast(f, to: SetFlag.self)(true) }
            }
        }
        let app = NSApplication.shared
        let sel = NSSelectorFromString("accessibilitySetOverrideValue:forAttribute:")
        guard app.responds(to: sel) else { return }
        for key in ["AXEnhancedUserInterface", "AXManualAccessibility"] { _ = app.perform(sel, with: NSNumber(value: true), with: key as NSString) }
    }

    nonisolated static func spinRunLoop(_ seconds: TimeInterval) { _ = CFRunLoopRunInMode(.defaultMode, seconds, false) }
    /// The folder the PNGs go to: MUSIC_SNAPSHOT_DIR, else a fresh temp folder (the same one for the whole run).
    static let outputDirectory: URL = {
        let fm = FileManager.default
        let url: URL
        if let p = ProcessInfo.processInfo.environment["MUSIC_SNAPSHOT_DIR"], !p.isEmpty { url = URL(fileURLWithPath: p, isDirectory: true) }
        else { url = fm.temporaryDirectory.appendingPathComponent("music-snapshots-\(Int(Date().timeIntervalSince1970))", isDirectory: true) }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func render<V: View>(_ view: V, size: CGSize, environment env: MusicSnapshotEnvironment, settle: TimeInterval = 0.6) async throws -> MusicSnapshotResult {
        _ = NSApplication.shared
        // Ask AppKit to build the accessibility tree even though no assistive client is attached.
        _ = NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

        let saved = (ThemeStore.current, ThemeStore.state.userAccent, ThemeStore.state.userContrast, ThemeStore.state.frostedOnly)
        let defaults = UserDefaults.standard
        let savedStep = defaults.object(forKey: MusicTextStep.defaultsKey)
        ThemeStore.current = env.theme
        ThemeStore.state.userAccent = MusicSnapshotStyle.accent(named: env.accentName)
        ThemeStore.state.userContrast = env.increaseContrast
        ThemeStore.state.frostedOnly = true          // native glass renders blank outside a real window
        defaults.set(env.textStep.rawValue, forKey: MusicTextStep.defaultsKey)
        defer {
            ThemeStore.current = saved.0; ThemeStore.state.userAccent = saved.1; ThemeStore.state.userContrast = saved.2; ThemeStore.state.frostedOnly = saved.3
            if let savedStep { defaults.set(savedStep, forKey: MusicTextStep.defaultsKey) } else { defaults.removeObject(forKey: MusicTextStep.defaultsKey) }
        }

        let host = NSHostingView(rootView: AnyView(view.modifier(MusicSnapshotEnvironmentModifier(env: env))))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: env.dark ? .darkAqua : .aqua)
        win.isReleasedWhenClosed = false
        win.setFrameOrigin(NSPoint(x: -(size.width + 400), y: 60))        // off every screen, so the live app window is never touched
        win.orderFrontRegardless()
        defer { win.contentView = nil; win.close() }

        Self.enableAccessibilityTree()
        let end = Date().addingTimeInterval(settle)
        while Date() < end { try await Task.sleep(nanoseconds: 40_000_000); Self.spinRunLoop(0.02) }

        let started = Date()
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw MusicSnapshotError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), let cg = rep.cgImage else { throw MusicSnapshotError.noBitmap }
        let seconds = Date().timeIntervalSince(started)
        let stats = pixelStats(rep)
        let elements = accessibilityElements(of: host)
        return MusicSnapshotResult(image: cg, png: png, fitting: fitting, elements: elements, windowFrame: win.frame, renderSeconds: seconds,
                                   stddev: stats.stddev, distinctColours: stats.distinct)
    }

    // MARK: pixels

    /// Standard deviation of luminance (0...255) and the number of distinct 4-bit colours over a sparse grid of pixels.
    static func pixelStats(_ rep: NSBitmapImageRep) -> (stddev: Double, distinct: Int) {
        guard let data = rep.bitmapData, rep.bitsPerPixel >= 24 else { return (0, 0) }
        let bpp = rep.bitsPerPixel / 8, w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        let sx = max(1, w / 160), sy = max(1, h / 160)
        var n = 0.0, sum = 0.0, sumSq = 0.0
        var seen = Set<UInt16>()
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * rowBytes + x * bpp
                let r = Double(data[o]), g = Double(data[o + 1]), b = Double(data[o + 2])
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                n += 1; sum += l; sumSq += l * l
                seen.insert(UInt16(data[o] >> 4) << 8 | UInt16(data[o + 1] >> 4) << 4 | UInt16(data[o + 2] >> 4))
                x += sx
            }
            y += sy
        }
        guard n > 0 else { return (0, 0) }
        let mean = sum / n
        return (max(0, sumSq / n - mean * mean).squareRoot(), seen.count)
    }

    // MARK: accessibility

    private static func attribute(_ object: AnyObject, _ key: String) -> Any? {
        guard let o = object as? NSObject, o.responds(to: NSSelectorFromString(key)) else { return nil }
        return o.value(forKey: key)
    }

    /// Every element the accessibility tree exposes (depth first, bounded). Empty when AppKit builds no tree in this process.
    static func accessibilityElements(of root: NSView) -> [MusicSnapshotAXElement] {
        var out: [MusicSnapshotAXElement] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: AnyObject, depth: Int) {
            guard depth < 48, out.count < 6000, visited.insert(ObjectIdentifier(node)).inserted else { return }
            let role = (attribute(node, "accessibilityRole") as? String) ?? ""
            let label = (attribute(node, "accessibilityLabel") as? String) ?? ""
            let frame = (attribute(node, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            if !role.isEmpty { out.append(MusicSnapshotAXElement(role: role, label: label, frame: frame)) }
            var kids: [Any] = []
            for key in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityVisibleChildren"] { kids += (attribute(node, key) as? [Any]) ?? [] }
            for child in kids { walk(child as AnyObject, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }

    // MARK: contact sheet

    /// All sizes of one scenario side by side, each labelled with its size (and a red mark when a check failed).
    static func contactSheet(title: String, cells: [(label: String, image: CGImage, failed: Bool)], cellHeight: CGFloat = 360) -> Data? {
        guard !cells.isEmpty else { return nil }
        let pad: CGFloat = 12, labelH: CGFloat = 26, titleH: CGFloat = 30
        let widths = cells.map { CGFloat($0.image.width) / CGFloat(max(1, $0.image.height)) * cellHeight }
        let totalW = Int((widths.reduce(0, +) + pad * CGFloat(cells.count + 1)).rounded(.up))
        let totalH = Int((titleH + labelH + cellHeight + pad * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: totalW, height: totalH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        MusicSnapshotStyle.sheetBackground.setFill()
        NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()
        func text(_ s: String, at p: NSPoint, failed: Bool = false) {
            s.draw(at: p, withAttributes: [.font: MusicSnapshotStyle.sheetFont, .foregroundColor: failed ? MusicSnapshotStyle.sheetFailure : MusicSnapshotStyle.sheetText])
        }
        text(title, at: NSPoint(x: pad, y: CGFloat(totalH) - titleH + 4))
        var x = pad
        for (i, c) in cells.enumerated() {
            ctx.draw(c.image, in: CGRect(x: x, y: pad, width: widths[i], height: cellHeight))
            text(c.label + (c.failed ? "  FAILED" : ""), at: NSPoint(x: x, y: pad + cellHeight + 4), failed: c.failed)
            x += widths[i] + pad
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

enum MusicSnapshotError: Error, CustomStringConvertible {
    case noBitmap
    var description: String { "the view could not be drawn into a bitmap" }
}
