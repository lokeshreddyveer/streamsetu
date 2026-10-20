import SwiftUI

/// Settings: words to watch for in the guide.
struct KeywordAlertsGroup: View {
    @Environment(\.container) private var container
    @State private var word = ""
    @State private var message: String?

    var body: some View {
        if let service = container?.alerts {
            SettingsGroup(title: "Guide alerts", footer: "Add a word, such as a sport, a team or a show. When a programme with that word is coming up in the next day and a half, you get a reminder a minute before it starts, once. Needs Programme reminders to be on.") {
                ForEach(service.keywords, id: \.self) { k in
                    HStack { Text(k); Spacer(); Button(role: .destructive) { service.remove(k) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                }
                HStack {
                    TextField("Add a word to watch for", text: $word).onSubmit { add(service) }
                    Button("Add") { add(service) }.disabled(KeywordAlertService.clean(word).count < 2)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if !service.lastFound.isEmpty { VStack(alignment: .leading, spacing: 2) { Text("Last set up").font(.caption).foregroundStyle(.secondary); ForEach(service.lastFound.prefix(5), id: \.self) { Text($0).font(.caption) } } }
                SettingsActions { Button { Task { let n = await service.scan(); message = n == 0 ? "Nothing new coming up." : "\(n) reminder\(n == 1 ? "" : "s") set." } } label: { Label("Look Now", systemImage: "bell.badge") } }
            }
        }
    }

    private func add(_ service: KeywordAlertService) {
        if service.add(word) { word = ""; message = nil } else { message = "That word is already there, too short, or you have 20 already." }
    }
}
