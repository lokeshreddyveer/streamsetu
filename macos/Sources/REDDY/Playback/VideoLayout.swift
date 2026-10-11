import Foundation
import CoreGraphics

/// How the picture is sized inside the player. This is *presentation* scaling; it never changes the stream's resolution.
enum VideoSizeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto = "Auto", fit = "Fit", fill = "Fill", original = "Original Size", stretch = "Stretch"
    var id: String { rawValue }
}

enum AspectRatioOption: Codable, Hashable, Sendable, Identifiable {
    case original, r16x9, r4x3, r21x9, r235, r1x1
    case custom(width: Double, height: Double)

    static let presets: [AspectRatioOption] = [.original, .r16x9, .r4x3, .r21x9, .r235, .r1x1]

    var id: String { title }

    /// Width / height, or nil for "use the source's own aspect ratio".
    var value: Double? {
        switch self {
        case .original: nil
        case .r16x9: 16.0 / 9
        case .r4x3: 4.0 / 3
        case .r21x9: 21.0 / 9
        case .r235: 2.35
        case .r1x1: 1
        case .custom(let w, let h): w > 0 && h > 0 ? w / h : nil
        }
    }

    var title: String {
        switch self {
        case .original: "Original"
        case .r16x9: "16:9"
        case .r4x3: "4:3"
        case .r21x9: "21:9"
        case .r235: "2.35:1"
        case .r1x1: "1:1"
        case .custom(let w, let h): "Custom \(w.formatted(.number.precision(.fractionLength(0...2)))):\(h.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }
}

struct VideoLayoutSettings: Codable, Equatable, Sendable {
    var mode: VideoSizeMode = .auto
    var aspect: AspectRatioOption = .original
    var zoom: Double = 1
    /// Pan as a fraction (-1…1) of the maximum travel the zoomed picture allows.
    var panX: Double = 0
    var panY: Double = 0

    static let zoomPresets: [Double] = [1, 1.25, 1.5, 1.75, 2]
    static let zoomRange: ClosedRange<Double> = 1...3
    static let `default` = VideoLayoutSettings()

    var isDefault: Bool { self == .default }

    mutating func setZoom(_ z: Double) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, z))
        if zoom == 1 { panX = 0; panY = 0 }
    }

    mutating func reset() { self = .default }
}

/// Pure geometry for the video rectangle (in the container's coordinate space, origin top-left).
/// The result may extend beyond the container when filling or zooming; the host view clips it.
enum VideoLayoutCalculator {
    /// - Parameters:
    ///   - container: size of the player area, in points.
    ///   - source: the video's display size in pixels (0 when not yet known).
    ///   - backingScale: pixels per point, used by "Original Size".
    static func videoRect(container: CGSize, source: CGSize, settings: VideoLayoutSettings, backingScale: CGFloat = 1) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let full = CGRect(origin: .zero, size: container)
        // Until the stream reports a size there is nothing meaningful to preserve.
        guard source.width > 0, source.height > 0 else { return full }

        let sourceAspect = Double(source.width / source.height)
        let aspect = settings.aspect.value ?? sourceAspect

        var base: CGSize
        switch settings.mode {
        case .stretch:
            base = container
        case .original:
            let h = Double(source.height / max(1, backingScale))
            base = CGSize(width: h * aspect, height: h)
        case .fill:
            base = scaled(aspect: aspect, container: container, cover: true)
        case .auto, .fit:
            base = scaled(aspect: aspect, container: container, cover: false)
        }

        let zoom = min(VideoLayoutSettings.zoomRange.upperBound, max(1, settings.zoom))
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        let maxX = max(0, (size.width - container.width) / 2), maxY = max(0, (size.height - container.height) / 2)
        let px = min(1, max(-1, settings.panX)), py = min(1, max(-1, settings.panY))
        return CGRect(x: (container.width - size.width) / 2 + px * maxX,
                      y: (container.height - size.height) / 2 + py * maxY,
                      width: size.width, height: size.height)
    }

    private static func scaled(aspect: Double, container: CGSize, cover: Bool) -> CGSize {
        let containerAspect = Double(container.width / container.height)
        let widthLimited = cover ? aspect < containerAspect : aspect >= containerAspect
        if widthLimited { return CGSize(width: container.width, height: container.width / aspect) }
        return CGSize(width: container.height * aspect, height: container.height)
    }

    /// Converts a drag in points into a new pan value, clamped to the available travel.
    static func pan(_ settings: VideoLayoutSettings, dragging delta: CGSize, container: CGSize, source: CGSize, backingScale: CGFloat = 1) -> VideoLayoutSettings {
        var s = settings
        let rect = videoRect(container: container, source: source, settings: VideoLayoutSettings(mode: settings.mode, aspect: settings.aspect, zoom: settings.zoom), backingScale: backingScale)
        let maxX = max(0, (rect.width - container.width) / 2), maxY = max(0, (rect.height - container.height) / 2)
        if maxX > 0 { s.panX = min(1, max(-1, s.panX + Double(delta.width / maxX))) } else { s.panX = 0 }
        if maxY > 0 { s.panY = min(1, max(-1, s.panY + Double(delta.height / maxY))) } else { s.panY = 0 }
        return s
    }

    /// Standard player sizes (layout points). Theater and fullscreen are determined by the window and display.
    enum WindowPreset: String, CaseIterable, Sendable {
        case mini = "Mini", small = "Small", medium = "Medium", large = "Large"
        var size: CGSize {
            switch self { case .mini: CGSize(width: 320, height: 180); case .small: CGSize(width: 480, height: 270); case .medium: CGSize(width: 800, height: 450); case .large: CGSize(width: 1280, height: 720) }
        }
    }
}
