import SwiftUI
import MessageUI

/// Report a problem or suggest something. It becomes an email from the person's own mail app, so nothing is sent without them seeing it.
struct FeedbackView: View {
    @Environment(\.container) private var container
    @Environment(\.openURL) private var openURL
    @State private var kind: FeedbackKind = .problem
    @State private var text = ""
    @State private var includeDiagnostics = true
    @State private var diagnostics: String?
    @State private var showMail = false
    @State private var shareAutomatically = DiagnosticsUploader.shared.isEnabled
    @State private var sharingNow = false
    @State private var shareNote: String?
    @State private var sharedPreview = ""

    private var message: FeedbackMessage { FeedbackMessage(kind: kind, text: text, diagnostics: includeDiagnostics ? diagnostics : nil) }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) { ForEach(FeedbackKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                TextEditor(text: $text).frame(minHeight: 150)
            } footer: { Text(kind == .problem ? "What went wrong, and what were you doing? The more detail, the easier it is to fix." : "What would you like StreamSetu to do?") }.listRowBackground(ColorTokens.surface)
            if kind == .problem {
                Section {
                    Toggle("Include diagnostics", isOn: $includeDiagnostics)
                    if includeDiagnostics, let diagnostics {
                        DisclosureGroup("See what is included") { Text(diagnostics).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }
                } footer: { Text("Version, device, playlist hosts, counts and recent playback errors. Never logins, passwords or full stream addresses.") }.listRowBackground(ColorTokens.surface)
            }
            Section {
                Toggle("Share playback logs automatically", isOn: $shareAutomatically)
                    .onChange(of: shareAutomatically) { _, on in DiagnosticsUploader.shared.isEnabled = on }
                Button { sendLogNow() } label: { Label(sharingNow ? "Sending…" : "Send My Log Now", systemImage: "paperplane") }.disabled(sharingNow)
                if let shareNote { Text(shareNote).font(.footnote).foregroundStyle(ColorTokens.textSecondary) }
                DisclosureGroup("See exactly what is sent") {
                    Text(sharedPreview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            } header: { Text("Help fix playback problems") } footer: {
                Text("Off until you turn it on. When it is on and a stream fails for good, StreamSetu sends the recent playback log to the developer: what was tried, which player, error codes, your app and iOS version and device model. Server names are replaced with server-1, server-2… Never logins, passwords, playlist names, titles or stream addresses. Kept for 30 days. You can turn it off here any time; you can also send one log by hand.")
            }.listRowBackground(ColorTokens.surface)
            Section {
                Button { send() } label: { Label("Send by Email", systemImage: "envelope") }
                ShareLink(item: message.fullText) { Label("Share or Copy Instead", systemImage: "square.and.arrow.up") }
                Button("Clear Playback Log", role: .destructive) { PlaybackLog.shared.clear(); Task { await loadDiagnostics() } }
            } footer: { Text("This opens your mail app with the message ready, addressed to \(FeedbackMessage.address). Nothing is sent until you press Send there.") }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Send Feedback").themed("Send Feedback")
        .task { await loadDiagnostics(); loadSharedPreview() }
        .sheet(isPresented: $showMail) { MailView(message: message).ignoresSafeArea() }
    }

    private func sendLogNow() {
        sharingNow = true; shareNote = nil
        let note = text
        Task {
            let ok = await DiagnosticsUploader.shared.send(trigger: "manual", note: note)
            sharingNow = false
            shareNote = ok ? "Sent. Thank you." : "Couldn't send. Check your connection and try again."
        }
    }

    private func loadSharedPreview() {
        let p = DiagnosticsUploader.shared.payload(trigger: "manual")
        let head = ["install_id", "app_version", "build", "platform", "os_version", "device"].map { "\($0 == "install_id" ? "report number" : $0): \(p[$0] as? String ?? "")" }
        sharedPreview = (head + ((p["log"] as? [String]) ?? [])).joined(separator: "\n")
    }

    private func send() {
        if MFMailComposeViewController.canSendMail() { showMail = true }
        else if let url = message.mailtoURL { UIPasteboard.general.string = message.fullText; openURL(url) }
    }

    private func loadDiagnostics() async {
        guard let c = container else { return }
        let title = c.playback.current?.title
        diagnostics = await Task.detached { c.diagnostics.report(playback: title, engines: ["Apple AVPlayer"]) }.value
    }
}

private struct MailView: UIViewControllerRepresentable {
    let message: FeedbackMessage
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([FeedbackMessage.address])
        vc.setSubject(message.subject)
        vc.setMessageBody(message.body, isHTML: false)
        if let d = message.diagnostics, let data = d.data(using: .utf8) { vc.addAttachmentData(data, mimeType: "text/plain", fileName: "StreamSetu-diagnostics.txt") }
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) { dismiss() }
    }
}
