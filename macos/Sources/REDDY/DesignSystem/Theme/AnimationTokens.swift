import SwiftUI

enum AnimationTokens {
    static let quick = Animation.easeOut(duration: 0.14)        // short interaction 120-160 ms
    static let standard = Animation.easeInOut(duration: 0.2)    // standard transition 180-240 ms
    static let layout = Animation.easeInOut(duration: 0.28)     // large layout transition 250-320 ms
    static let hover = Animation.smooth(duration: 0.22)         // pointer enter/leave: no overshoot
    static let press = Animation.snappy(duration: 0.12)
    static let page = Animation.smooth(duration: 0.24)          // content crossfade between tabs
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
}
