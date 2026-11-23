import SwiftUI

/// Reminders that are set, with their permission state, a Cancel on each and "Cancel all".
struct GuideRemindersList: View {
    @Environment(\.container) private var container
    @State private var items: [GuideReminderItem] = []
    @State private var permission: GuideReminderPermission = .unavailable
    @AppStorage(ReminderService.leadKey) private var lead = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reminders").font(.headline)
            if permission == .denied { Text("Notifications are switched off for this app. Turn them on in the system settings to get reminders.").font(.callout).foregroundStyle(.secondary) }
            else if permission == .notDetermined { Button("Allow reminders") { Task { _ = await container?.reminders.requestAuthorization(); await reload() } }.atlas("setting.remindersEnabled") }
            Picker("Remind me before", selection: $lead) { ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }.pickerStyle(.menu).fixedSize().atlas("setting.guide.reminderLeadMinutes")
            if items.isEmpty { Text("No reminders set. Open a programme in the TV Guide and choose Remind Me.").font(.callout).foregroundStyle(.secondary) }
            ForEach(items) { i in
                HStack {
                    VStack(alignment: .leading) { Text(i.title); Text(i.detail).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { container?.reminders.cancel(programID: i.programID); Task { await reload() } } label: { Image(systemName: "bell.slash") }.buttonStyle(.borderless).accessibilityLabel("Cancel reminder").atlas("setting.remindersEnabled")
                }
            }
            if items.count > 1 { Button("Cancel all reminders") { Task { await container?.reminders.cancelAllProgrammeReminders(); await reload() } }.atlas("setting.remindersEnabled") }
        }
        .atlas("setting.remindersEnabled")
        .task { await reload() }
    }
    private func reload() async {
        guard let r = container?.reminders else { return }
        permission = await r.permission(); items = await r.pending()
    }
}
