import CoreGraphics

enum LayoutTokens {
    /// The persistent top bar. Fixed: it never changes with content, window state or scrolling.
    static let headerHeight: CGFloat = 54
    static let sidebarWidth: CGFloat = 184
    static let sidebarCollapsedWidth: CGFloat = 64
    static let playerBarHeight: CGFloat = 76
    static let gutter: CGFloat = 12
    static let radiusSmall: CGFloat = 9
    static let radius: CGFloat = 12
    static let radiusPanel: CGFloat = 16
    static let radiusLarge: CGFloat = 22
    static let posterSize = CGSize(width: 150, height: 218)
    static let landscapeCard = CGSize(width: 240, height: 135)
    static let channelLogo = CGSize(width: 28, height: 28)
    static let miniPlayerHeight: CGFloat = 76
    static let guideRowHeight: CGFloat = 48
    static let guideChannelWidth: CGFloat = 180
    static let channelListWidth: CGFloat = 290
}
