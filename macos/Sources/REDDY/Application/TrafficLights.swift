import SwiftUI
import AppKit

/// The window's close, minimise and zoom buttons, drawn by the app so they sit exactly in the middle of the top bar. They stay out of sight
/// until the pointer is in the top-left corner (see `WindowChrome`), then fade in; with the pointer on them each shows its symbol.
struct TrafficLights: View {
    @State private var corner = false
    @State private var overButtons = false
    @State private var fullScreen = false

    private var shown: Bool { (corner || overButtons) && !fullScreen }

    var body: some View {
        HStack(spacing: 8) {
            light(.red, symbol: "xmark", label: "Close") { NSApp.keyWindow?.performClose(nil) }
            light(.yellow, symbol: "minus", label: "Minimise") { NSApp.keyWindow?.miniaturize(nil) }
            light(.green, symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .onHover { overButtons = $0 }
        .padding(.leading, 18)
        .frame(height: LayoutTokens.headerHeight)
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: shown)
        .allowsHitTesting(shown)
        .onReceive(NotificationCenter.default.publisher(for: .trafficLightsCorner)) { corner = ($0.userInfo?["hot"] as? Bool) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }

    private enum Kind { case red, yellow, green
        var fill: Color { switch self { case .red: Color(red: 1.0, green: 0.37, blue: 0.34); case .yellow: Color(red: 1.0, green: 0.74, blue: 0.18); case .green: Color(red: 0.16, green: 0.78, blue: 0.25) } }
    }

    private func light(_ kind: Kind, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(kind.fill)
                Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.5)
                Image(systemName: symbol).font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.black.opacity(0.58)).opacity(overButtons ? 1 : 0)
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
