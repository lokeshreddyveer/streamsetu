import SwiftUI
import AVFoundation
import CoreVideo
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Soft light around a music video. A 64 px wide copy of the current frame is sampled onto a 32 x 18 grid, blurred and eased in `MusicAmbientMath`, and the
// result is shown as a small image stretched over the view (the stretch is the blur). It redraws at most 15 times a second, only while a video is playing and
// the view is on screen; paused, it holds the last picture and runs nothing. Without a video frame it shows colours from the cover, once.

@MainActor @Observable
final class MusicAmbientGlowModel {
    private(set) var image: CGImage?
    @ObservationIgnored private var grid: [SIMD3<Float>]?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var outputItem: AVPlayerItem?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var coverFrame: MusicAmbientFrame?
    @ObservationIgnored private(set) var coverURL: String?
    @ObservationIgnored var picture = CGRect(x: 0.14, y: 0.14, width: 0.72, height: 0.72)
    @ObservationIgnored var aspect = 16.0 / 9.0

    /// True when the player's current item has a picture to sample.
    func hasVideo(_ player: AVPlayer?) -> Bool {
        guard let item = player?.currentItem else { return false }
        return item.tracks.contains { $0.assetTrack?.mediaType == .video }
    }

    func setCover(_ url: String?) async {
        guard url != coverURL else { return }
        coverURL = url
        coverFrame = nil
        guard let url, let baked = await MusicAdaptiveColorCache.shared.wash(for: url), coverURL == url else { return }
        coverFrame = MusicAmbientMath.frame(fromRGBA: baked.rgba, width: MusicCoverWash.side, height: MusicCoverWash.side)
        if output == nil || image == nil { grid = nil; render(coverFrame, dt: 0) }
    }

    /// One redraw: from the video when it has a frame, else from the cover.
    func tick(player: AVPlayer?, now: Date = Date()) {
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        if let f = videoFrame(player) { render(f, dt: dt) } else if image == nil || output == nil { render(coverFrame, dt: dt) }
    }

    /// The next frame after a pause starts from the picture on screen, not from a stale time.
    func resetClock() { lastTick = nil }

    private func render(_ frame: MusicAmbientFrame?, dt: Double) {
        guard let frame, frame.width > 0 else { return }
        let c = MusicAmbientMath.columns, r = MusicAmbientMath.rows
        let sampled = MusicAmbientMath.blur(MusicAmbientMath.sample(frame, picture: picture, columns: c, rows: r), columns: c, rows: r)
        let next = MusicAmbientMath.smooth(previous: grid, new: sampled, dt: dt)
        grid = next
        let bytes = MusicAmbientMath.pixels(next, columns: c, rows: r, picture: picture, aspect: aspect)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return }
        image = CGImage(width: c, height: r, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func videoFrame(_ player: AVPlayer?) -> MusicAmbientFrame? {
        guard let item = player?.currentItem, hasVideo(player) else { detach(); return nil }
        if outputItem !== item {
            detach()
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(o)
            output = o; outputItem = item
        }
        guard let o = output else { return nil }
        let t = item.currentTime()
        guard let buffer = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return nil }
        return Self.frame(from: buffer)
    }

    private func detach() {
        if let o = output { outputItem?.remove(o) }
        output = nil; outputItem = nil
    }

    func stop() { detach() }

    /// A 64 px wide RGBA copy by point sampling a BGRA buffer (a few thousand reads, no allocation of the full frame).
    nonisolated static func frame(from buffer: CVPixelBuffer) -> MusicAmbientFrame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let ow = min(64, w), oh = max(1, h * ow / w)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        for y in 0..<oh { for x in 0..<ow {
            let sx = min(w - 1, x * w / ow + w / (2 * ow)), sy = min(h - 1, y * h / oh + h / (2 * oh))
            let s = sy * stride + sx * 4, d = (y * ow + x) * 4
            out[d] = p[s + 2]; out[d + 1] = p[s + 1]; out[d + 2] = p[s]
        } }
        return MusicAmbientFrame(width: ow, height: oh, rgba: out)
    }
}

/// The glow itself, to sit behind a video surface. `picture` is where the video is, in the glow's own 0...1 coordinates.
struct MusicAmbientGlowView: View {
    var player: AVPlayer?
    var isPlaying: Bool
    /// True when the playing track is a video with a video stream (`isVideo == true` and `MusicStream.hasVideo == true`). Without it the glow shows the cover once and never loops.
    var expectsVideo = true
    var cover: [MusicThumbnail] = []
    var picture = CGRect(x: 0.14, y: 0.14, width: 0.72, height: 0.72)
    /// Nil follows the person's setting ("Light around music videos", off by default).
    var enabled: Bool? = nil

    @AppStorage(MusicThemeSettings.ambientLightKey) private var setting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = MusicAmbientGlowModel()
    @State private var size = CGSize(width: 16, height: 9)

    private var on: Bool { enabled ?? setting }
    private struct LoopKey: Equatable { var playing: Bool; var on: Bool; var reduce: Bool; var video: Bool }

    var body: some View {
        Group {
            if on, let image = model.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).opacity(0.85)
            } else { Color.clear }
        }
        .background(GeometryReader { g in Color.clear.onChange(of: g.size, initial: true) { _, s in size = s; model.aspect = s.height > 0 ? Double(s.width / s.height) : 16.0 / 9.0 } })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: cover.best(minSide: 400)) { if on { await model.setCover(cover.best(minSide: 400)) } }
        .task(id: LoopKey(playing: isPlaying, on: on, reduce: reduceMotion, video: expectsVideo)) {
            model.picture = picture
            guard on else { model.stop(); return }
            model.resetClock()
            model.tick(player: player)
            // Paused, reduced motion or a cover only: one picture and no loop.
            guard isPlaying, !reduceMotion, expectsVideo else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / MusicAmbientMath.framesPerSecond))
                model.tick(player: player)
            }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - Video surface

#if os(macOS)
private final class MusicPlayerLayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
}

/// The picture of a playing music video. It draws whatever the player's current item shows and nothing else; the transport stays with the music player.
struct MusicVideoSurface: NSViewRepresentable {
    var player: AVPlayer?
    var cornerRadius: CGFloat = 12
    func makeNSView(context: Context) -> NSView { MusicPlayerLayerView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        guard let v = view as? MusicPlayerLayerView, let l = v.playerLayer else { return }
        if l.player !== player { l.player = player }
        l.videoGravity = .resizeAspect
        l.cornerRadius = cornerRadius; l.masksToBounds = true
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? MusicPlayerLayerView)?.playerLayer?.player = nil }
}
#else
private final class MusicPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct MusicVideoSurface: UIViewRepresentable {
    var player: AVPlayer?
    var cornerRadius: CGFloat = 12
    func makeUIView(context: Context) -> UIView { MusicPlayerLayerView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard let v = view as? MusicPlayerLayerView else { return }
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.cornerRadius = cornerRadius; v.playerLayer.masksToBounds = true
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? MusicPlayerLayerView)?.playerLayer.player = nil }
}
#endif

/// A music video with its glow: the picture is centred at 16:9 and the light spreads around it. Shows the glow alone (cover colours) when there is no video.
struct MusicVideoStage: View {
    var player: AVPlayer?
    var isPlaying: Bool
    var expectsVideo = true
    var cover: [MusicThumbnail] = []

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width * 0.72, g.size.height * 0.72 * 16 / 9), h = w * 9 / 16
            let rect = CGRect(x: (1 - w / max(g.size.width, 1)) / 2, y: (1 - h / max(g.size.height, 1)) / 2, width: w / max(g.size.width, 1), height: h / max(g.size.height, 1))
            ZStack {
                MusicAmbientGlowView(player: player, isPlaying: isPlaying, expectsVideo: expectsVideo, cover: cover, picture: rect)
                MusicVideoSurface(player: player).frame(width: w, height: h)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}
