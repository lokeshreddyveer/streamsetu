import SwiftUI

/// StreamSetu never asks, on a first launch or at any other time, whether it may send playback logs: sharing is off until the person turns it on in Settings → Send Feedback, and the
/// switch there is the only way to turn it on. This modifier is kept (every root view still applies it) but shows nothing.
struct LoggingNotice: ViewModifier {
    /// Whether a notice is to be shown. Never: there is no first-launch prompt.
    static func shouldAsk(available: Bool, alreadyShown: Bool) -> Bool { false }

    func body(content: Content) -> some View { content }
}

extension View {
    func loggingNotice() -> some View { modifier(LoggingNotice()) }
}
