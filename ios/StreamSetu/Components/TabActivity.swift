import SwiftUI

private struct TabActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// True when the screen this view belongs to is the one on show. The tabs stay built after they are first opened (so their scroll position and open pages are remembered) and are
    /// only hidden, so a hidden tab is still "on screen" as far as SwiftUI knows. Anything that runs by itself (a slideshow, a clock, polling) must stop while this is false.
    var tabActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}
