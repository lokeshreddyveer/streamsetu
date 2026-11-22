import SwiftUI
import Observation

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    let text: String
    let symbol: String
    let kind: Kind
    /// Label of an action button ("Undo"); its closure is kept by the center, so the toast stays Equatable.
    var actionTitle: String? = nil
}

@MainActor @Observable
final class ToastCenter {
    private(set) var items: [Toast] = []

    private var actions: [UUID: @MainActor () -> Void] = [:]
    func run(_ id: UUID) { let a = actions[id]; dismiss(id); a?() }

    func show(_ text: String, symbol: String = "info.circle.fill", kind: Toast.Kind = .info, duration: Double = 4.5, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let t = Toast(text: CredentialRedactor.redact(text), symbol: symbol, kind: kind, actionTitle: action == nil ? nil : actionTitle)
        if let action { actions[t.id] = action }
        items.append(t)
        if items.count > 4 { let dropped = items.removeFirst(); actions[dropped.id] = nil }          // its action closure goes with it
        AccessibilityNotification.Announcement(t.text).post()
        Task { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)); dismiss(t.id) }
    }

    func dismiss(_ id: UUID) { items.removeAll { $0.id == id }; actions[id] = nil }
}

struct ToastHost: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            ForEach(center.items) { t in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: t.symbol).foregroundStyle(color(t.kind))
                    Text(t.text).font(Typography.bodyMedium).lineLimit(3)
                    if let title = t.actionTitle { Button(title) { center.run(t.id) }.buttonStyle(.plain).font(Typography.bodyMedium).foregroundStyle(ColorTokens.accentDefault) }
                    Button { center.dismiss(t.id) } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
                .frame(maxWidth: 420, alignment: .leading)
                .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous).strokeBorder(ColorTokens.borderStrong))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                // A message rises in with a spring and settles; it slides away when dismissed.
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                        removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .padding(Spacing.lg)
        .animation(reduceMotion ? nil : AnimationTokens.spring, value: center.items)
        .allowsHitTesting(!center.items.isEmpty)
    }

    private func color(_ k: Toast.Kind) -> Color {
        switch k { case .info: ColorTokens.textSecondary; case .success: ColorTokens.success; case .warning: ColorTokens.warning; case .error: ColorTokens.danger }
    }
}
