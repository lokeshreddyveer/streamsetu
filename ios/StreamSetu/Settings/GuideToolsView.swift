import SwiftUI

/// Subscriptions (when each playlist ends) and guide alerts (words to watch for in the guide).
struct GuideToolsView: View {
    @Environment(\.container) private var container
    @State private var rows: [(name: String, status: AccountStatus)] = []
    @State private var word = ""
    @State private var message: String?

    var body: some View {
        Form {
            if let accounts = container?.accounts {
                Section {
                    if rows.isEmpty { Text("Nothing reported yet.").foregroundStyle(.secondary) }
                    ForEach(rows, id: \.name) { r in
                        LabeledContent(r.name) { Text(r.status.summary()).foregroundStyle(r.status.level() == .fine ? Color.secondary : Color.orange).multilineTextAlignment(.trailing) }
                    }
                    Button(accounts.checking ? "Checking…" : "Check Now") { Task { await accounts.refresh(force: true); load(accounts) } }
                } header: { Text("Subscriptions") } footer: { Text("Asked of each provider that reports it (Xtream), at most twice a day. You are warned from a week before one ends.") }
                .listRowBackground(ColorTokens.surface)
                .task { load(accounts); await accounts.refresh(); load(accounts) }
            }
            if let alerts = container?.alerts {
                Section {
                    ForEach(alerts.keywords, id: \.self) { k in Text(k) }.onDelete { idx in idx.map { alerts.keywords[$0] }.forEach(alerts.remove) }
                    HStack { TextField("Add a word to watch for", text: $word).onSubmit { add(alerts) }; Button("Add") { add(alerts) }.disabled(KeywordAlertService.clean(word).count < 2) }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    ForEach(alerts.lastFound.prefix(5), id: \.self) { Text($0).font(.caption) }
                    Button("Look Now") { Task { let n = await alerts.scan(); message = n == 0 ? "Nothing new coming up." : "\(n) reminder\(n == 1 ? "" : "s") set." } }
                } header: { Text("Guide alerts") } footer: { Text("Add a word, such as a sport, a team or a show. When a programme with that word is coming up in the next day and a half, you get a reminder a minute before it starts, once. Needs Programme reminders to be on.") }
                .listRowBackground(ColorTokens.surface)
            }
        }
        .navigationTitle("Subscriptions and Alerts").themed("Subscriptions and Alerts")
    }

    private func add(_ alerts: KeywordAlertService) { if alerts.add(word) { word = ""; message = nil } else { message = "That word is already there, too short, or you have 20 already." } }

    private func load(_ service: AccountStatusService) {
        let names = Dictionary(uniqueKeysWithValues: ((try? container?.catalog.sources()) ?? []).map { ($0.id, $0.name) })
        rows = service.statuses.compactMap { id, st in names[id].map { ($0, st) } }.sorted { $0.name < $1.name }
    }
}
