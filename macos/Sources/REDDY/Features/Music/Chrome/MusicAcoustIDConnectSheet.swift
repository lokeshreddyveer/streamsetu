import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Connects the person's AcoustID account. The app asks AcoustID for a link, shows the code and an Open button, and checks every few seconds while this sheet is on
/// screen. The key AcoustID returns is kept in the Keychain from the start but is used for lookups only after the person approves. Closing the sheet leaves a waiting
/// link in place, and reopening it (or relaunching) resumes the same one.
struct MusicAcoustIDConnectSheet: View {
    let close: () -> Void
    private let connection = AcoustIDConnection()
    @State private var status: AcoustIDConnection.Status = .notConnected
    @State private var busy = false
    @State private var polling: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Connect AcoustID")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.acoustidConnectClose")
            }
            Text(Localized.string("AcoustID asks each person to connect their own account before songs can be recognised. Approve this app on the AcoustID website; no password is entered here.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            content
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 460, idealWidth: 520)
        .task { status = await connection.current(); if case .pending = status { startPolling() } }
        .onDisappear { polling?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .notConnected:
            Button(Localized.string("Connect AcoustID")) { Task { await begin() } }.musicButton(.primary, size: .regular).disabled(busy).atlas("control.music.acoustidConnect")
        case .pending(let code, let url, let expires):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(Localized.string("Waiting for your approval")).font(Typography.bodyMedium)
                Text(verbatim: code).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Text(Localized.string("The code works until %@.", expires.formatted(date: .abbreviated, time: .shortened))).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                HStack {
                    Button(Localized.string("Open approval page")) { open(url) }.musicButton(.primary, size: .compact).atlas("control.music.acoustidOpen")
                    Button(copied ? Localized.string("Copied") : Localized.string("Copy code")) { copy(code) }.musicButton(.secondary, size: .compact).atlas("control.music.acoustidCopyCode")
                    Button(Localized.string("Cancel")) { Task { polling?.cancel(); status = await connection.cancel() } }.musicButton(.secondary, size: .compact).atlas("control.music.acoustidCancel")
                }
            }
        case .connected(let manual):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(manual ? Localized.string("A key you pasted is saved.") : Localized.string("Connected to your AcoustID account.")).font(Typography.bodyMedium).foregroundStyle(ColorTokens.success)
                Text(Localized.string("Disconnecting removes the key from this Mac only. It stays valid on AcoustID until you disconnect this app on your connected applications page at acoustid.org.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                Button(Localized.string("Disconnect")) { Task { status = await connection.disconnect() } }.musicButton(.secondary, size: .compact).atlas("control.music.acoustidDisconnect")
            }
        case .ended(let why):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(Self.message(why)).musicText(.secondary).foregroundStyle(ColorTokens.danger)
                Button(Localized.string("Try again")) { Task { await begin() } }.musicButton(.primary, size: .compact).atlas("control.music.acoustidRetry")
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: MusicSpace.sm) {
                Text(MusicAcoustIDSheet.message(error)).musicText(.secondary).foregroundStyle(ColorTokens.danger)
                Button(Localized.string("Try again")) { Task { await begin() } }.musicButton(.primary, size: .compact).atlas("control.music.acoustidRetry")
            }
        }
    }

    static func message(_ why: AcoustIDLinkOutcome) -> String {
        switch why {
        case .declined: Localized.string("The request was declined on AcoustID.")
        case .expired: Localized.string("The code ran out before it was approved.")
        case .revoked: Localized.string("This app was disconnected on AcoustID.")
        case .unknown: Localized.string("AcoustID no longer knows this connection.")
        }
    }

    private func begin() async {
        busy = true; defer { busy = false }
        status = await connection.begin()
        if case .pending = status { startPolling() }
    }

    /// Checks every few seconds while this sheet is open; stops on any answer that ends the wait.
    private func startPolling() {
        polling?.cancel()
        polling = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                let s = await connection.check()
                status = s
                if case .pending = s { continue }
                return
            }
        }
    }

    private func open(_ url: String) {
        #if os(macOS)
        // Only AcoustID's own https address is opened.
        guard let u = URL(string: url), u.scheme == "https", let host = u.host, host == "acoustid.org" || host.hasSuffix(".acoustid.org") else { return }
        NSWorkspace.shared.open(u)
        #endif
    }

    private func copy(_ code: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
    }
}
