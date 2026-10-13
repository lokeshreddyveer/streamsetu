import SwiftUI
import AppKit

/// Report a problem or suggest something. It becomes an email from the person's own mail app, so nothing is sent without them seeing it.
struct FeedbackWindow: View {
    @Environment(\.container) private var container
    @State private var kind: FeedbackKind = .problem
    @State private var text = ""
    @State private var includeDiagnostics = true
    @State private var diagnostics: String?
    @State private var note: String?
    @State private var shareAutomatically = DiagnosticsUploader.shared.isEnabled
    @State private var sharingNow = false

    private var message: FeedbackMessage { FeedbackMessage(kind: kind, text: text, diagnostics: includeDiagnostics ? diagnostics : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Send Feedback").font(Typography.title)
            Picker("", selection: $kind) { ForEach(FeedbackKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $text).font(Typography.body).frame(height: 160).padding(6)
                .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border))
            Text(kind == .problem ? "What went wrong, and what were you doing? The more detail, the easier it is to fix." : "What would you like StreamSetu to do?")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            if kind == .problem {
                Toggle("Include diagnostics (version, Mac, playlist hosts, counts, recent playback errors; never logins or full stream addresses)", isOn: $includeDiagnostics)
                    .font(Typography.caption)
                if includeDiagnostics, let diagnostics {
                    DisclosureGroup("See what is included") {
                        ScrollView { Text(diagnostics).font(Typography.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 140)
                    }.font(Typography.caption)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Share playback logs automatically", isOn: $shareAutomatically)
                    .onChange(of: shareAutomatically) { _, on in DiagnosticsUploader.shared.isEnabled = on }
                Text("On by default. When a stream fails for good, StreamSetu sends the recent playback log to the developer: what was tried, which player, error codes, your app and macOS version and Mac model. Server names are replaced with server-1, server-2… Never logins, passwords, playlist names, titles or stream addresses. Kept for 30 days.")
                    .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                SecondaryButton(title: sharingNow ? "Sending…" : "Send My Log Now", symbol: "paperplane") { sendLogNow() }.disabled(sharingNow)
            }
            if let note { Text(note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            HStack {
                Text("Opens your mail app, addressed to \(FeedbackMessage.address). Nothing is sent until you press Send there.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                Spacer()
                SecondaryButton(title: "Clear Playback Log", symbol: "trash") { PlaybackLog.shared.clear(); Task { await loadDiagnostics() }; note = "Playback log cleared." }
                SecondaryButton(title: "Copy", symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.fullText, forType: .string); note = "Copied." }
                PrimaryButton(title: "Send by Email", symbol: "envelope") { send() }
            }
        }
        .padding(Spacing.section).frame(width: 560).background(ColorTokens.background)
        .task { await loadDiagnostics() }
    }

    private func sendLogNow() {
        sharingNow = true; note = nil
        let typed = text
        Task {
            let ok = await DiagnosticsUploader.shared.send(trigger: "manual", note: typed)
            sharingNow = false
            note = ok ? "Log sent. Thank you." : "Couldn't send the log. Check your connection and try again."
        }
    }

    private func send() {
        let m = message
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [FeedbackMessage.address]
            service.subject = m.subject
            var items: [Any] = [m.body]
            if let d = m.diagnostics {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("StreamSetu-diagnostics.txt")
                if (try? d.write(to: file, atomically: true, encoding: .utf8)) != nil { items.append(file) }
            }
            if service.canPerform(withItems: items) { service.perform(withItems: items); return }
        }
        // No mail account set up: copy the whole message and open a plain mail link.
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.fullText, forType: .string)
        if let url = m.mailtoURL { NSWorkspace.shared.open(url) }
        note = "No mail account is set up here, so the whole message was copied. Paste it into an email to \(FeedbackMessage.address)."
    }

    private func loadDiagnostics() async {
        guard let c = container else { return }
        let engines = c.playback.availableEngines.contains(.mpv) ? ["AVPlayer", "MPV"] : ["AVPlayer"]
        let title = c.playback.current?.title
        diagnostics = await Task.detached { c.diagnostics.report(playback: title, engines: engines) }.value
    }
}
