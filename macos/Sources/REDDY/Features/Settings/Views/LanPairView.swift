import SwiftUI

/// "Add a device": lists the devices found on this network and pairs with the one the person picks. Both people compare the same six digits.
struct LanPairView: View {
    let service: LanSyncService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a device").font(.title2.weight(.semibold))
            if let p = service.prompt {
                VStack(spacing: 14) {
                    Text("Does \(p.peerName) show the same number?").multilineTextAlignment(.center)
                    Text(p.digits).font(.system(size: 44, weight: .semibold, design: .monospaced)).kerning(4)
                    HStack(spacing: 12) {
                        Button("They Match") { service.answer(true) }.buttonStyle(.borderedProminent)
                        Button("They Don't", role: .destructive) { service.answer(false) }
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .transition(.opacity)
            } else {
                Text("Open Settings › Sync on this network on your other device, then Add a device there too. Pick it below.").font(.callout).foregroundStyle(.secondary)
                let fresh = service.found.filter { f in !service.trusted.contains { $0.id == f.id } }
                if fresh.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for devices on this network…").foregroundStyle(.secondary) }
                } else {
                    ForEach(fresh) { f in
                        Button { Task { await service.pair(with: f) } } label: {
                            HStack { Image(systemName: "laptopcomputer.and.iphone"); Text(f.name); Spacer(); Text("Pair").foregroundStyle(.secondary) }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if let m = service.pairingMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 320)
        .animation(.easeInOut(duration: 0.25), value: service.prompt?.id)
        .onAppear { service.setPairing(open: true) }
        .onDisappear { service.setPairing(open: false) }
    }
}
