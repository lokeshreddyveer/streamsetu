import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focusToken: Int = 0
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ColorTokens.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textTertiary).help("Clear").accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(ColorTokens.card, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.7) : ColorTokens.border))
        .onChange(of: focusToken) { _, _ in focused = true }
        .onAppear { if autofocus { focused = true } }
    }
}
