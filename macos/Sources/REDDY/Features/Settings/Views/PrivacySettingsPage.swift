import SwiftUI

/// What StreamSetu keeps and what it can send, as it is now.
struct PrivacyReportGroup: View {
    @Environment(\.container) private var container
    var body: some View {
        if let container {
            SettingsGroup(title: "Privacy report", footer: "This follows the privacy policy and shows your current settings. Nothing here is sent anywhere.") { PrivacyReportView(container: container) }
        }
    }
}

/// Shown only when the saved logins cannot be opened (another Mac's file, a lost key, a hardware id that changed). Nothing is deleted: the old file is kept whole in a folder of its own.
struct SavedLoginsGroup: View {
    @Environment(\.container) private var container
    @State private var problem: String?
    @State private var kept: URL?
    @State private var failed: String?

    var body: some View {
        Group {
            if let store = container?.credentials as? StandardCredentialStore {
                if let problem {
                    SettingsGroup(title: "Saved logins", footer: "Starting a new set keeps the old file in a folder of its own and deletes nothing. You enter your logins again; the old ones can still be opened later on the Mac that made them.") {
                        Text(problem).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        SettingsActions {
                            Button {
                                do { kept = try store.startFreshVault(); failed = nil; self.problem = nil }
                                catch { failed = error.localizedDescription }
                            } label: { Label("Start a New Set and Keep the Old File", systemImage: "arrow.counterclockwise") }
                        }
                        if let failed { Text(failed).font(.callout).foregroundStyle(.red) }
                    }
                } else if let kept {
                    SettingsGroup(title: "Saved logins", footer: "A new set was started. The old file was kept whole in this folder.") {
                        #if os(macOS)
                        SettingsActions { Button { NSWorkspace.shared.activateFileViewerSelecting([kept]) } label: { Label("Show the Kept File", systemImage: "folder") } }
                        #endif
                    }
                }
            }
        }
        .task { if let store = container?.credentials as? StandardCredentialStore, case .locked(let why) = store.vaultHealth { problem = why } }
    }
}

struct PrivacySettingsPage: View {
    var body: some View {
        SettingsPage {
            SavedLoginsGroup()
            PrivacyReportGroup()
            ParentalSettingsGroup()
            AppLockSettingsGroup()
            ProxySettingsGroup()
            AppDNSSettingsGroup()
            VPNSettingsGroup()
        }
    }
}
