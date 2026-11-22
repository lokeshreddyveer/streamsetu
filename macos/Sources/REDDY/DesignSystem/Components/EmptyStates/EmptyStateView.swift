import SwiftUI

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.md) {
            // Drawn, gently moving art chosen from the symbol the screen asks for (a television tuning, a magnifier, a bookmark …).
            BrandEmptyArt(symbol: symbol, size: 84)
            Text(title.loc).font(Typography.heading)
            if let message { Text(message.loc).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420) }
            if let actionTitle, let action { PrimaryButton(title: actionTitle, action: action).padding(.top, Spacing.sm) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.page)
    }
}
