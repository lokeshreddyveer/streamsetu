import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Put on the root of a window. Draws Show-me over everything under it while a session is running (on the Mac, only in the window that has the keyboard, so the Settings window and the main window never both draw it).
    func atlasShowMeHost(_ controller: ShowMeController = .shared) -> some View { modifier(ShowMeHost(controller: controller)) }
}

struct ShowMeHost: ViewModifier {
    let controller: ShowMeController
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    private var isFront: Bool { activeState == .key }
    #else
    private var isFront: Bool { true }
    #endif

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(AtlasFramesKey.self) { anchors in
            GeometryReader { proxy in
                if controller.session != nil && isFront {
                    ShowMeOverlay(controller: controller, frames: anchors.mapValues { proxy[$0] }, size: proxy.size, insets: ShowMeInsets.resolve(proxy.safeAreaInsets))
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// The overlay ignores the safe area (the dim covers the whole window), which also zeroes the insets it reads: on iPhone the card then sat under the clock. Ask the window for the real ones.
enum ShowMeInsets {
    @MainActor static func resolve(_ read: EdgeInsets) -> EdgeInsets {
        #if canImport(UIKit)
        if read.top == 0 && read.bottom == 0,
           let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            let i = w.safeAreaInsets
            return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
        }
        #endif
        return read
    }
}

/// Dims the window, cuts a hole around the control, and shows a short card with Back, Next and Done. Taps pass through the hole and nowhere else.
struct ShowMeOverlay: View {
    let controller: ShowMeController
    let frames: [String: CGRect]
    let size: CGSize
    let insets: EdgeInsets
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or the debug launch flag `--atlas-reduce-motion` (the simulator cannot be switched from outside; the UI test asserts what this reads).
    private var reduceMotion: Bool { systemReduceMotion || AtlasProbe.reduceMotion }
    @FocusState private var keyboardFocus: Bool
    @AccessibilityFocusState private var cardFocused: Bool

    private static let cardWidth: CGFloat = 340
    private static let padding: CGFloat = 8

    var body: some View {
        if let session = controller.session {
            let resolution = session.resolve(frames: frames)
            ZStack(alignment: .topLeading) {
                dim(resolution)
                if case .spotlight(let r) = resolution { ring(r.insetBy(dx: -Self.padding, dy: -Self.padding)) }
                card(session, resolution)
            }
            .frame(width: size.width, height: size.height)
            .focusable().focused($keyboardFocus).focusEffectDisabled()
            .onKeyPress(.escape) { controller.finish(); return .handled }
            .onKeyPress(.rightArrow) { controller.next(); return .handled }
            .onKeyPress(.leftArrow) { controller.back(); return .handled }
            .onAppear { keyboardFocus = true }
            .task(id: controller.tick) {
                // Once per step: bring the control into sight if the page can scroll, say what is happening, move VoiceOver to the card.
                if let a = session.current.anchor, !isOnScreen(frames[a]) { controller.scrollIntoView(a) }
                AccessibilityNotification.Announcement(session.announcement(resolution)).post()
                cardFocused = true
            }
            .accessibilityAddTraits(.isModal)
            .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private func isOnScreen(_ r: CGRect?) -> Bool {
        guard let r else { return false }
        return CGRect(origin: .zero, size: size).intersects(r)
    }

    // MARK: layers

    private func hole(_ r: CGRect) -> Path { Path(roundedRect: r.insetBy(dx: -Self.padding, dy: -Self.padding), cornerRadius: 10) }

    private func dim(_ resolution: ShowMeResolution) -> some View {
        var path = Path(CGRect(origin: .zero, size: size))
        if case .spotlight(let r) = resolution { path.addPath(hole(r)) }
        return path.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .contentShape(path, eoFill: true)          // the hole is not hit-testable, so the control under it still works
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: resolution)
            .accessibilityHidden(true)
    }

    private func ring(_ r: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ColorTokens.accent, lineWidth: 2)
            RoundedRectangle(cornerRadius: 9, style: .continuous).inset(by: 2).strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
        }
        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        .allowsHitTesting(false).accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: r)
    }

    // MARK: card

    private func card(_ session: ShowMeSession, _ resolution: ShowMeResolution) -> some View {
        let width = min(Self.cardWidth, max(220, size.width - 32))
        var placeAbove = false, x = (size.width - width) / 2
        if case .spotlight(let r) = resolution {
            placeAbove = r.midY > size.height / 2
            x = min(max(16, r.midX - width / 2), size.width - width - 16)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Button { controller.finish() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close").accessibilityIdentifier("showme.close")
            }
            if session.showsProgress { Text(session.progress).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(session.current.say).font(.body).fixedSize(horizontal: false, vertical: true)
            note(session, resolution)
            HStack(spacing: 8) {
                if !session.isFirst { Button("Back") { controller.back() }.buttonStyle(.bordered) }
                Spacer()
                if session.isLast { Button("Done") { controller.finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("showme.done") }
                else { Button("Next") { controller.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("showme.next") }
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("Show me").accessibilityAddTraits(.isModal)
        .overlay(alignment: .topLeading) { if AtlasProbe.enabled { AtlasProbeView(identifier: "atlas.showme.reduceMotion:\(reduceMotion)") } }          // debug walk only: lets a UI test see which setting the overlay read
        .accessibilityFocused($cardFocused)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placeAbove ? .topLeading : .bottomLeading)
        .padding(.leading, x).padding(.top, placeAbove ? insets.top + 16 : 0).padding(.bottom, placeAbove ? 0 : insets.bottom + 16)
    }

    @ViewBuilder private func note(_ session: ShowMeSession, _ resolution: ShowMeResolution) -> some View {
        switch resolution {
        case .missing(let title, let canOpen):
            VStack(alignment: .leading, spacing: 8) {
                Text(canOpen ? "I can't find it on this screen. Open \(title) first." : "I can't find it on this screen. Open \(title) and try again.").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if canOpen { Button { controller.openCurrentScreen() } label: { Label("Open \(title)", systemImage: "arrow.up.forward.app") }.buttonStyle(.bordered) }
            }
        case .openedButNotFound(let title):
            Text("I opened \(title). Look for it there.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .spotlight, .caption:
            if session.current.guideOnly { Text("Setu only shows you this one. You change it yourself.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
