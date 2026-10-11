import SwiftUI
import MetricKit

/// Receives crash diagnostics from the system and, only when the person has said yes, keeps them on the device.
final class CrashCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashCollector()
    static let key = "settings.crashreports"
    private var keeping: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard keeping else { return }
        for p in payloads where !(p.crashDiagnostics ?? []).isEmpty { CrashReports.save(p.jsonRepresentation()) }
    }
}

struct CrashReportsView: View {
    @AppStorage(CrashCollector.key) private var keep = false
    @State private var reports: [CrashReports.Report] = []

    var body: some View {
        List {
            Section {
                Toggle("Keep crash reports on this device", isOn: $keep)
            } footer: {
                Text("Off by default. When on, if StreamSetu ever crashes, the system's report is saved here. Nothing is sent anywhere; you decide whether to share one.")
            }.listRowBackground(ColorTokens.surface)
            Section("Saved reports") {
                if reports.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(reports) { r in
                    ShareLink(item: r.url) { Label(r.date.formatted(date: .abbreviated, time: .shortened), systemImage: "square.and.arrow.up") }
                }
                if !reports.isEmpty { Button("Delete All", role: .destructive) { CrashReports.removeAll(); reports = CrashReports.list() } }
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Crash Reports").themed("Crash Reports")
        .onAppear { reports = CrashReports.list() }
    }
}
