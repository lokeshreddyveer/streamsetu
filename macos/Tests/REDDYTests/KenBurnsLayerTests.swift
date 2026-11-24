import Testing
import SwiftUI
import AppKit
import QuartzCore
@testable import REDDY

/// The Mac hero drift runs as a Core Animation layer animation (render server), not as a SwiftUI animation (a window layout every frame).
@MainActor struct KenBurnsLayerTests {
    static func pump(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    static let image = TitlePageFixture.cgImage(width: 1280, height: 720, hue: 0.3, poster: false)

    final class CountingHost<R: View>: NSHostingView<R> {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    static func window(_ content: NSView, size: CGSize = CGSize(width: 640, height: 360)) -> NSWindow {
        content.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = content; win.setFrameOrigin(NSPoint(x: 40, y: 40)); win.orderFront(nil)
        return win
    }

    @Test func driftIsALayerAnimationWithTheSameLook() throws {
        let view = KenBurnsLayerView(frame: .zero)
        let win = Self.window(view)
        view.configure(image: Self.image, animated: true, fadeIn: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.isAnimating)
        let group = try #require(view.artLayer.animation(forKey: KenBurnsMotion.key) as? CAAnimationGroup)
        #expect(group.duration == 9)
        let scale = try #require(group.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform.scale" })
        #expect((scale.fromValue as? NSNumber)?.doubleValue == 1)
        #expect((scale.toValue as? NSNumber)?.doubleValue == 1.03)
        #expect(group.animations?.contains { ($0 as? CABasicAnimation)?.keyPath == "transform.translation.x" } == true)
        #expect(view.artLayer.contentsGravity == .resizeAspectFill)
        // The model layer is untouched: the render server does the moving.
        #expect(CATransform3DIsIdentity(view.artLayer.transform))
        win.orderOut(nil)
    }

    @Test func stillWithReduceMotion() {
        let view = KenBurnsLayerView(frame: .zero)
        let win = Self.window(view)
        view.configure(image: Self.image, animated: false, fadeIn: false)
        #expect(!view.isAnimating)
        // Turning motion back on starts it; turning it off removes it.
        view.configure(image: Self.image, animated: true, fadeIn: false); #expect(view.isAnimating)
        view.configure(image: Self.image, animated: false, fadeIn: false); #expect(!view.isAnimating)
        win.orderOut(nil)
    }

    @Test func reduceMotionSettingKeepsTheSwiftUIWrapperStill() throws {
        UserDefaults.standard.set(true, forKey: DefaultsKey.reduceMotion); defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.reduceMotion) }
        let host = NSHostingView(rootView: KenBurnsArtwork(url: nil).frame(width: 320, height: 180))
        let win = Self.window(host, size: CGSize(width: 320, height: 180))
        Self.pump(0.3)
        #expect(Self.find(KenBurnsLayerView.self, in: host)?.isAnimating == false)
        win.orderOut(nil)
    }

    static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let v = view as? V { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    @Test func noPerFrameSwiftUIWork() throws {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.reduceMotion)
        let host = CountingHost(rootView: KenBurnsArtwork(url: nil).frame(width: 640, height: 360))
        let win = Self.window(host)
        Self.pump(0.5)
        let before = host.layouts
        Self.pump(1.5)
        #expect(host.layouts - before < 10, "layouts in 1.5 s: \(host.layouts - before)")
        win.orderOut(nil)
    }

    @Test func layerLooksLikeTheSwiftUIPicture() throws {
        // At the end of the drift (scale 1.03) the layer shows the same picture as SwiftUI's aspect-fill scaled the same way.
        let size = CGSize(width: 600, height: 300)
        let view = KenBurnsLayerView(frame: NSRect(origin: .zero, size: size))
        view.configure(image: Self.image, animated: false, fadeIn: false)
        view.layoutSubtreeIfNeeded(); view.layout()
        view.artLayer.contentsScale = 1
        view.artLayer.transform = CATransform3DMakeScale(1.03, 1.03, 1)
        func bitmap(_ draw: (CGContext) -> Void) -> [UInt8] {
            let ctx = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(ctx)
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: p, count: ctx.bytesPerRow * 300))
        }
        let a = bitmap { view.layer!.render(in: $0) }
        let r = ImageRenderer(content: Image(decorative: Self.image, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(width: 600, height: 300)
            .scaleEffect(1.03).clipped())
        r.scale = 1
        let img = try #require(r.cgImage)
        let b = bitmap { $0.draw(img, in: CGRect(x: 0, y: 0, width: 600, height: 300)) }
        var total = 0, n = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) { for c in 0..<3 { total += abs(Int(a[i + c]) - Int(b[i + c])); n += 1 } }
        let mean = Double(total) / Double(max(1, n))
        #expect(mean < 6, "mean channel difference \(mean)")
    }
}
