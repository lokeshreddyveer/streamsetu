import SwiftUI

/// Settings: when each playlist's subscription ends, as the provider reports it.
struct SubscriptionsGroup: View {
    @Environment(\.container) private var container
    @State private var rows: [(name: String, status: AccountStatus)] = []

    var body: some View {
        if let service = container?.accounts {
            SettingsGroup(title: "Subscriptions", footer: "Asked of each provider that reports it (Xtream), at most twice a day. You are warned from a week before one ends.") {
                if rows.isEmpty { Text("Nothing reported yet.").foregroundStyle(.secondary) }
                ForEach(rows, id: \.name) { r in
                    SettingsValueRow(title: r.name, value: r.status.summary(), tone: r.status.level() == .fine ? .normal : .warning)
                    if let m = r.status.maxConnections { SettingsValueRow(title: "   Streams at once", value: "\(m)") }
                }
                SettingsActions { Button { Task { await service.refresh(force: true); load(service) } } label: { Label(service.checking ? "Checking…" : "Check Now", systemImage: "arrow.clockwise") } }
            }
            .task { load(service); await service.refresh(); load(service) }
        }
    }

    private func load(_ service: AccountStatusService) {
        let names = Dictionary(uniqueKeysWithValues: ((try? container?.catalog.sources()) ?? []).map { ($0.id, $0.name) })
        rows = service.statuses.compactMap { id, st in names[id].map { ($0, st) } }.sorted { $0.name < $1.name }
    }
}
