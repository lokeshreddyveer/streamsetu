import SwiftUI

/// What has already played in this run of the app, so the opening plays once and not again when a window or a scene is made again.
enum OpeningPlayed { @MainActor static var done = false }

/// The first moment of the app: the mark and the name come up out of the dark, glow slowly for about six seconds, and fade away into the app. A tap skips it. With Reduce Motion on, it only fades.
struct OpeningAnimation<Mark: View>: View {
    let mark: Mark
    let onDone: () -> Void
    @State private var shown: CGFloat = 0
    @State private var leaving = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder mark: () -> Mark, onDone: @escaping () -> Void) { self.mark = mark(); self.onDone = onDone }

    var body: some View {
        ZStack {
            ColorTokens.background.ignoresSafeArea()
            VStack(spacing: 18) {
                mark.frame(width: 104, height: 104)
                    .shadow(color: ColorTokens.accentDefault.opacity((glow ? 0.55 : 0.2) * shown), radius: glow ? 44 : 22)
                    .scaleEffect(reduceMotion ? 1 : 0.82 + 0.18 * shown)
                Text("StreamSetu").font(.system(size: 30, weight: .bold)).tracking(0.5)
                Text("Your streams. One home.").font(.system(size: 14)).foregroundStyle(.secondary).opacity(shown)
            }
            .opacity(shown).offset(y: reduceMotion ? 0 : (1 - shown) * 14)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityHidden(true)
        .task {
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 1.0)) { shown = 1 }
            if !reduceMotion { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true } }
            do { try await Task.sleep(nanoseconds: reduceMotion ? 500_000_000 : 5_700_000_000) } catch { return }          // a cancelled wait must not end the opening early
            finish()
        }
    }

    private func finish() {
        guard !leaving else { return }
        OpeningPlayed.done = true
        withAnimation(.easeIn(duration: 0.3)) { leaving = true }
        Task { try? await Task.sleep(nanoseconds: 320_000_000); onDone() }
    }
}
