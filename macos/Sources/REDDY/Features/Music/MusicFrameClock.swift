import SwiftUI

/// The one frame clock the Music screens use. It pauses when the caller says so and whenever the app is in the background,
/// so an idle or hidden Music screen costs no CPU.
struct MusicFrameClock<Content: View>: View {
    var minimumInterval: Double? = nil
    var paused = false
    @ViewBuilder var content: (TimelineViewDefaultContext) -> Content
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused || scenePhase == .background)) { ctx in
            content(ctx)
        }
    }
}
