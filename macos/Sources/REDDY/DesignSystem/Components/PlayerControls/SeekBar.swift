import SwiftUI

/// Scrubber with a draggable thumb. Reports the target only when the drag ends, so seeking isn't spammed.
struct SeekBar: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @Environment(\.reddyAccent) private var accent
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let frac = dragging ?? (duration > 0 ? min(1, max(0, position / duration)) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: hovering || dragging != nil ? 6 : 4)
                Capsule().fill(accent).frame(width: g.size.width * frac, height: hovering || dragging != nil ? 6 : 4)
                Circle().fill(.white).frame(width: 14, height: 14).offset(x: max(0, g.size.width * frac - 7)).opacity(hovering || dragging != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / max(1, g.size.width))) }
                .onEnded { v in
                    let f = min(1, max(0, v.location.x / max(1, g.size.width)))
                    dragging = nil; onSeek(f * duration)
                })
        }
        .frame(height: 20)
        .animation(AnimationTokens.quick, value: hovering)
        .accessibilityLabel("Seek")
        .accessibilityValue("\(DurationFormatter.clock(position)) of \(DurationFormatter.clock(duration))")
    }
}
