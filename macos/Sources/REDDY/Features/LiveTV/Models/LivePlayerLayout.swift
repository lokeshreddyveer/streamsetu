import CoreGraphics

/// The geometry rules for the Live TV player, kept free of views so they can be tested. None of this touches playback:
/// the stage only decides how big the picture's box is; the video surface letterboxes inside it.
enum LivePlayerLayout {
    /// Used until the stream reports its real size.
    static let placeholderAspect: CGFloat = 16.0 / 9
    static let minStageHeight: CGFloat = 180
    static let listRange: ClosedRange<CGFloat> = 260...360
    static let minPlayerWidth: CGFloat = 420

    /// Display aspect ratio (width ÷ height) from the stream's real dimensions, or 16:9 until they are known. Implausible
    /// values (a 1×1000 first report) fall back to the placeholder so the layout never jumps to something absurd.
    static func displayAspect(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return placeholderAspect }
        let r = CGFloat(width) / CGFloat(height)
        return (0.5...3.0).contains(r) ? r : placeholderAspect
    }

    /// The video box. It always takes the full width of the column, so the controls span it too. Its height is the picture's
    /// height at that width (width ÷ aspect), limited so the information below keeps `reservedBelow` points and never below
    /// `minHeight`. When the height is the limit the picture is narrower than the box and the video surface centres it with
    /// black bars; it is never stretched or cropped.
    static func stageSize(available: CGSize, aspect: CGFloat, reservedBelow: CGFloat, minHeight: CGFloat = minStageHeight) -> CGSize {
        guard available.width > 0, available.height > 0, aspect > 0 else { return CGSize(width: max(0, available.width), height: minHeight) }
        let room = max(minHeight, available.height - reservedBelow)
        return CGSize(width: available.width.rounded(.down), height: min(available.width / aspect, room).rounded(.down))
    }

    /// Channel list width: the stored choice, kept inside its range and never so wide that the player drops below
    /// `minPlayerWidth`. In a narrow window it shrinks to the minimum rather than squeezing the controls.
    static func channelListWidth(stored: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let wanted = min(listRange.upperBound, max(listRange.lowerBound, stored))
        let allowed = containerWidth - minPlayerWidth
        return max(listRange.lowerBound, min(wanted, allowed))
    }

    /// The bottom strip repeats what the Live TV player already shows, so it is hidden while that player has the video.
    static func shouldShowMiniPlayer(onLiveTV: Bool, isLive: Bool, livePreviewVisible: Bool, hasPlayback: Bool) -> Bool {
        guard hasPlayback else { return false }
        return !(onLiveTV && isLive && livePreviewVisible)
    }
}
