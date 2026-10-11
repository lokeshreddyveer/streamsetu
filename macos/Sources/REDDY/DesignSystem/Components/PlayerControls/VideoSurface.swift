import SwiftUI
import AVFoundation
import AVKit

/// Hosts the shared video layers. The same AVPlayer is reused for every channel; SwiftUI re-creating this view
/// (navigation, resizing) only re-attaches a layer and never restarts playback.
final class PlayerHostView: NSView {
    private let avLayer = AVPlayerLayer()
    private var mpvLayer: AVSampleBufferDisplayLayer?
    private var layoutSettings = VideoLayoutSettings()
    private var videoSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true            // zoomed / filled video is clipped to the player area
        avLayer.videoGravity = .resize         // the layer frame is computed by VideoLayoutCalculator
        layer?.addSublayer(avLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applyFrame()
    }

    private func applyFrame() {
        let rect = VideoLayoutCalculator.videoRect(container: bounds.size, source: videoSize, settings: layoutSettings, backingScale: window?.backingScaleFactor ?? 2)
        // CALayer's origin is bottom-left; the calculator's is top-left.
        let flipped = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        avLayer.frame = flipped
        mpvLayer?.frame = flipped
        CATransaction.commit()
    }

    /// Lets go of the shared layers so another view can take them. A libmpv display layer has one parent, and a second
    /// AVPlayerLayer on the same player would render a second copy of the video.
    func detach() {
        guard avLayer.player != nil || mpvLayer != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        avLayer.player = nil
        if let m = mpvLayer, m.superlayer === layer { m.removeFromSuperlayer() }
        mpvLayer = nil
        CATransaction.commit()
    }

    func configure(engine: PlaybackEngineKind, player: AVPlayer, mpv: AVSampleBufferDisplayLayer?, layout: VideoLayoutSettings, videoSize: CGSize) {
        mpv?.videoGravity = .resize
        if avLayer.player !== player { avLayer.player = player; MainActor.assumeIsolated { PiPManager.shared.register(avLayer) } }
        avLayer.isHidden = engine != .avPlayer
        if let mpv, mpvLayer !== mpv {
            mpvLayer?.removeFromSuperlayer()
            layer?.addSublayer(mpv); mpvLayer = mpv
        }
        mpvLayer?.isHidden = engine != .mpv
        if layoutSettings != layout || self.videoSize != videoSize { layoutSettings = layout; self.videoSize = videoSize; applyFrame() }
    }
}

struct VideoSurface: NSViewRepresentable {
    let playback: PlaybackCoordinator
    var owner: SurfaceOwner = .embedded

    func makeNSView(context: Context) -> PlayerHostView { PlayerHostView() }

    static func dismantleNSView(_ view: PlayerHostView, coordinator: ()) { view.detach() }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        guard playback.surfaceOwner == owner else { view.detach(); return }
        view.configure(engine: playback.activeEngine, player: playback.avPlayer, mpv: playback.mpvLayer, layout: playback.videoLayout, videoSize: playback.videoSize)
    }
}

/// Picture-in-Picture for the AVPlayer engine.
@MainActor
final class PiPManager: NSObject {
    static let shared = PiPManager()
    private var controller: AVPictureInPictureController?
    private weak var layer: AVPlayerLayer?
    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func register(_ l: AVPlayerLayer) {
        guard isSupported else { return }
        if controller == nil || layer !== l { layer = l; controller = AVPictureInPictureController(playerLayer: l) }
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else if c.isPictureInPicturePossible { c.startPictureInPicture() }
    }
}

struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}
