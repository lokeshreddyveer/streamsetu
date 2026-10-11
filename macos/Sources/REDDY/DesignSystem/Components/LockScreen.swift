import SwiftUI

/// What covers the app while it is locked.
struct LockScreen: View {
    let lock: AppLock
    var onUnlock: () -> Void = {}
    var body: some View {
        ZStack {
            ColorTokens.background.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 44, weight: .light)).foregroundStyle(ColorTokens.accentDefault)
                Text("StreamSetu is locked").font(.title3.weight(.semibold)).foregroundStyle(ColorTokens.textPrimary)
                Button { Task { await lock.unlock() } } label: { Label("Unlock with \(lock.method)", systemImage: "faceid").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(lock.isAuthenticating)
            }
        }
        .task { await lock.unlock() }
        .onChange(of: lock.isLocked) { _, locked in if !locked { onUnlock() } }
    }
}
