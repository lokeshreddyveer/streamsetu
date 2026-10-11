import SwiftUI
import Observation

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    let text: String
    let symbol: String
    let kind: Kind
}

@MainActor @Observable
final class ToastCenter {
    private(set) var items: [Toast] = []

    func show(_ text: String, symbol: String = "info.circle.fill", kind: Toast.Kind = .info, duration: Double = 4.5) {
        let t = Toast(text: CredentialRedactor.redact(text), symbol: symbol, kind: kind)
        items.append(t)
        if items.count > 4 { items.removeFirst() }
        Task { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)); dismiss(t.id) }
    }

    func dismiss(_ id: UUID) { items.removeAll { $0.id == id } }
}

struct ToastHost: View {
    let center: ToastCenter
    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            ForEach(center.items) { t in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: t.symbol).foregroundStyle(color(t.kind))
                    Text(t.text).font(Typography.bodyMedium).lineLimit(3)
                    Button { center.dismiss(t.id) } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
                .frame(maxWidth: 420, alignment: .leading)
                .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous).strokeBorder(ColorTokens.borderStrong))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(Spacing.lg)
        .animation(AnimationTokens.spring, value: center.items)
        .allowsHitTesting(!center.items.isEmpty)
    }

    private func color(_ k: Toast.Kind) -> Color {
        switch k { case .info: ColorTokens.textSecondary; case .success: ColorTokens.success; case .warning: ColorTokens.warning; case .error: ColorTokens.danger }
    }
}
