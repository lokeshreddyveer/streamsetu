import SwiftUI
import QuartzCore

/// The opening layer. It sits above the app, which is already being built underneath, and only draws what OpeningCoordinator says:
/// the frame for the stored start time, and an opacity that falls to nothing once the app is revealed. TimelineView only renders; it
/// never decides when the opening ends.
struct OpeningOverlay: View {
    var coordinator = OpeningCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if coordinator.isVisible {
                OpeningStage(coordinator: coordinator)
                    // In front of the app until it is revealed; from then on it takes no input at all.
                    .allowsHitTesting(coordinator.blocksInput)
                    .accessibilityHidden(!coordinator.blocksInput)
            }
            if coordinator.showsWhatsNew {
                WhatsNewView { withAnimation(.easeInOut(duration: 0.35)) { coordinator.finishWhatsNew() } }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: coordinator.showsWhatsNew)
        // Reduce Motion is the system's setting or the app's own "Reduce animation".
        .onAppear { coordinator.start(reduceMotion: reduceMotion || UserDefaults.standard.bool(forKey: DefaultsKey.reduceMotion)) }
    }
}

/// The opening on screen. It has no controls and answers no tap or key: it cannot be skipped, and it ends on time alone.
private struct OpeningStage: View {
    let coordinator: OpeningCoordinator
    /// Feeds the watchdog; a reference kept for the life of the stage, never part of what the view reads.
    @State private var monitor = OpeningFrameMonitor()

    var body: some View {
        // At most 60 frames a second (a 120 Hz screen would otherwise draw twice as many).
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: coordinator.frozenAt != nil)) { context in
            let now = context.date
            #if os(macOS)
            OpeningMacCanvas(theme: coordinator.theme, icons: OpeningIcons.current,
                             frame: { OpeningMacStory.frame(coordinator.drawnVariant, at: coordinator.storyTime(at: now)) },
                             onDraw: { ms in
                                 if coordinator.frozenAt == nil { monitor.frame(drawMs: ms) { [coordinator] reason in coordinator.abort(reason: reason) } }
                             })
                .opacity(coordinator.layerOpacity(at: now))
            #else
            Canvas { ctx, size in
                let began = CACurrentMediaTime()
                let ms = coordinator.storyTime(at: now)
                OpeningRenderer.draw(&ctx, size: size, frame: OpeningTimeline.frame(coordinator.drawnVariant, at: ms), art: OpeningArt.current, time: ms)
                if coordinator.frozenAt == nil {
                    monitor.frame(drawMs: (CACurrentMediaTime() - began) * 1000) { [coordinator] reason in coordinator.abort(reason: reason) }
                }
            }
            .opacity(coordinator.layerOpacity(at: now))
            #endif
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("StreamSetu. StreamSetu. The destination icons arrive one after another, settle into a row, and make way for the StreamSetu name.")
    }
}

// MARK: - What's New

/// The rows of What's New for this release. Edit them here at each release; keep only what is true for the platform.
enum WhatsNewContent {
    struct Row: Identifiable, Equatable {
        let symbol: String
        let title: String
        let text: String
        var id: String { title }
    }

    static var rows: [Row] {
        var rows = [
            Row(symbol: "sparkles", title: "A new opening", text: "Each destination takes the stage in turn, then they come together as the StreamSetu symbol."),
            Row(symbol: "bolt", title: "Start in seconds", text: "Paste a link or choose how you connect, on a redesigned welcome."),
        ]
        #if os(macOS)
        rows += [
            Row(symbol: "slider.horizontal.3", title: "Get set up", text: "Choose your Music, Podcasts and streaming services any time from the Help menu."),
            Row(symbol: "music.note", title: "Music, refined", text: "Explore by language, a redesigned Settings, and smoother crossfades."),
        ]
        #endif
        return rows
    }
}

/// Shown once after an update, when the opening has gone: what changed, then Continue.
struct WhatsNewView: View {
    var onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            StartBackdrop()
            GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("WHAT'S NEW").font(.system(size: 12, weight: .bold)).tracking(3.2).foregroundStyle(Color(hex: 0xA9B3BD))
                    Text("StreamSetu \(AppRelease.current)").font(.system(size: 40, weight: .bold)).tracking(-1)
                        .foregroundStyle(Color(hex: 0xF4F6F8)).padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(WhatsNewContent.rows.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .top, spacing: 16) {
                                icon(row.symbol)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: 0xF4F6F8))
                                    Text(row.text).font(.system(size: 14)).foregroundStyle(Color(hex: 0xA9B3BD)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown || reduceMotion ? 0 : 12)
                            .animation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.45).delay(0.08 + Double(index) * 0.05), value: shown)
                        }
                    }
                    .padding(.top, 32)
                    Button(action: onDone) {
                        Text("Continue").font(.system(size: 15, weight: .semibold)).foregroundStyle(StartStyle.isLight(ColorTokens.accent) ? Color(hex: 0x0B0D12) : .white)
                            .frame(minWidth: 180, minHeight: 46)
                            .background(Capsule().fill(ColorTokens.accent))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                            .shadow(color: ColorTokens.accent.opacity(0.3), radius: 12, y: 4)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 36)
                    .accessibilityIdentifier("whatsnew-continue")
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 56)
                // Centred in the window when it fits; it scrolls when it does not.
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { shown = true }
    }

    @ViewBuilder private func icon(_ symbol: String) -> some View {
        #if os(macOS)
        StartIconTile(symbol: symbol)
        #else
        StartIconBadge(symbol: symbol)
        #endif
    }
}
