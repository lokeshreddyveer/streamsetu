import SwiftUI

/// Digits only, shown as dots.
struct PINField: View {
    let title: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(title, text: Binding(get: { text }, set: { text = String($0.filter(\.isNumber).prefix(8)) }))
            .textFieldStyle(.roundedBorder).frame(width: 200).focused($focused).onSubmit(onSubmit)
            .accessibilityLabel(title)
            .onAppear { focused = true }
    }
}

/// Asks for the PIN to show locked folders for a while.
struct UnlockDialog: View {
    @Environment(\.container) private var container
    @Environment(AppRouter.self) private var router
    @State private var pin = ""
    @State private var message: String?

    var body: some View {
        ReddyDialog(title: "Unlock restricted content", width: 380, onClose: { router.modal = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Enter your PIN to show locked folders. They lock again by themselves after \(container?.parental.unlockMinutes ?? 15) minutes, when the Mac sleeps, and when StreamSetu restarts.")
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                PINField(title: "PIN", text: $pin, onSubmit: submit)
                if let message { Text(message.loc).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                HStack { Spacer(); SecondaryButton(title: "Cancel") { router.modal = nil }; PrimaryButton(title: "Unlock", action: submit).disabled(pin.count < 4) }
            }
        }
    }

    private func submit() {
        guard let p = container?.parental else { return }
        switch p.unlock(pin: pin) {
        case .unlocked: router.modal = nil
        case .wrongPIN(let left): message = "That isn't the PIN. \(left) \(left == 1 ? "try" : "tries") left."; pin = ""
        case .tooManyAttempts(let t): message = "Too many tries. Wait \(Int(t.rounded(.up))) seconds."; pin = ""
        case .noPIN: router.modal = nil
        }
    }
}

/// Creates a PIN, or changes the current one.
struct SetPINSheet: View {
    let changing: Bool
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(changing ? "Change PIN" : "Set a PIN").font(Typography.heading)
            Text("Four to eight digits. It is stored on this Mac only, as a salted hash. It keeps casual viewers out of locked folders; it isn't protection against someone who can open your Mac's files.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            if changing { PINField(title: "Current PIN", text: $current) }
            PINField(title: "New PIN", text: $new)
            PINField(title: "Repeat new PIN", text: $confirm, onSubmit: save)
            if let error { Text(error).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            HStack { Spacer(); SecondaryButton(title: "Cancel") { dismiss() }; PrimaryButton(title: "Save", action: save) }
        }
        .padding(22).frame(width: 380).background(ColorTokens.background)
    }

    private func save() {
        guard let p = container?.parental else { return }
        guard ParentalControls.isValidPIN(new) else { error = "Use four to eight digits."; return }
        guard new == confirm else { error = "The two PINs don't match."; return }
        if p.setPIN(new, current: changing ? current : nil) { dismiss() } else { error = changing ? "The current PIN isn't right." : "That PIN couldn't be saved." }
    }
}

/// Settings → General → Parental controls.
struct ParentalSettingsGroup: View {
    @Environment(\.container) private var container
    @State private var showSet = false
    @State private var showChange = false
    @State private var showRemove = false
    @State private var showUnlock = false
    @State private var removePIN = ""
    @State private var removeError: String?
    @State private var unlockPIN = ""
    @State private var unlockError: String?

    var body: some View {
        if let p = container?.parental {
            @Bindable var bp = p
            SettingsGroup(title: "Parental controls", footer: "Lock a folder from the sidebar (right-click) or from the Channel manager's Folders tab. While locked, its channels, movies and series are missing from every list and search.") {
                SettingsRow(title: "PIN", detail: p.hasPIN ? "A PIN is set." : "No PIN yet. Set one to lock folders.") {
                    if p.hasPIN {
                        HStack(spacing: 8) { Button("Change…") { showChange = true }; Button("Remove…") { showRemove = true } }
                    } else { Button("Set PIN…") { showSet = true } }
                }
                if p.hasPIN {
                    SettingsRow(title: "Locked folders", detail: p.lockedCategoryIDs.isEmpty ? "None yet." : "\(p.lockedCategoryIDs.count) folder\(p.lockedCategoryIDs.count == 1 ? "" : "s") locked.") { EmptyView() }
                    SettingsRow(title: "Unlock lasts", detail: "Then the folders lock again by themselves.") {
                        Picker("Unlock lasts", selection: Binding(get: { p.unlockMinutes }, set: { p.unlockMinutes = $0 })) {
                            ForEach([5, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                        }.pickerStyle(.menu).fixedSize()
                    }
                    SettingsRow(title: "Right now", detail: p.isUnlocked ? "Locked folders are visible." : "Locked folders are hidden.", divider: false) {
                        if p.isUnlocked { Button("Lock Now") { p.lockNow() } } else { Button("Unlock…") { showUnlock = true } }
                    }
                }
            }
            .sheet(isPresented: $showSet) { SetPINSheet(changing: false) }
            .sheet(isPresented: $showChange) { SetPINSheet(changing: true) }
            .sheet(isPresented: $showRemove) {
                promptSheet(title: "Remove PIN", note: "Enter the PIN to remove it. Folder locks are kept, but nothing is hidden without a PIN.", pin: $removePIN, error: removeError, action: "Remove") {
                    if p.removePIN(current: removePIN) { showRemove = false; removePIN = ""; removeError = nil } else { removeError = "That isn't the PIN." }
                }
            }
            .sheet(isPresented: $showUnlock) {
                promptSheet(title: "Unlock", note: "Enter your PIN to show locked folders.", pin: $unlockPIN, error: unlockError, action: "Unlock") {
                    switch p.unlock(pin: unlockPIN) {
                    case .unlocked, .noPIN: showUnlock = false; unlockPIN = ""; unlockError = nil
                    case .wrongPIN(let n): unlockError = "That isn't the PIN. \(n) left."; unlockPIN = ""
                    case .tooManyAttempts(let t): unlockError = "Too many tries. Wait \(Int(t.rounded(.up))) seconds."; unlockPIN = ""
                    }
                }
            }
        }
    }

    private func promptSheet(title: String, note: String, pin: Binding<String>, error: String?, action: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.loc).font(Typography.heading)
            Text(note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            PINField(title: "PIN", text: pin, onSubmit: run)
            if let error { Text(error).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            HStack { Spacer(); SecondaryButton(title: "Cancel") { showRemove = false; showUnlock = false }; PrimaryButton(title: action, action: run) }
        }
        .padding(22).frame(width: 360).background(ColorTokens.background)
    }
}


/// Shown in place of a locked folder's content: the PIN unlocks it right here.
struct LockedFolderView: View {
    let name: String
    @Environment(\.container) private var container
    @State private var pin = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .light)).foregroundStyle(ColorTokens.textSecondary)
            Text("“\(name)” is locked").font(Typography.title)
            Text("Enter your PIN to see what's inside. It locks again after \(container?.parental.unlockMinutes ?? 15) minutes.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            PINField(title: "PIN", text: $pin, onSubmit: submit)
            if let message { Text(message.loc).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            PrimaryButton(title: "Unlock", symbol: "lock.open", action: submit).disabled(pin.count < 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard let p = container?.parental else { return }
        switch p.unlock(pin: pin) {
        case .unlocked, .noPIN: break
        case .wrongPIN(let left): message = "That isn't the PIN. \(left) \(left == 1 ? "try" : "tries") left."; pin = ""
        case .tooManyAttempts(let t): message = "Too many tries. Wait \(Int(t.rounded(.up))) seconds."; pin = ""
        }
    }
}

struct AppLockSettingsGroup: View {
    @Environment(\.container) private var container

    var body: some View {
        if let lock = container?.appLock {
            SettingsGroup(title: "App lock", footer: "Asks for Touch ID or your Mac password when you open StreamSetu, after the screen sleeps, or after you have been away for 30 seconds. A stream that is playing keeps playing.") {
                SettingsRow(title: "Require \(lock.method)", detail: lock.canEnable ? "Off by default." : "Set a password on this Mac to use this.") {
                    Toggle("", isOn: Binding(get: { lock.enabled }, set: { v in Task { await lock.setEnabled(v) } })).labelsHidden().disabled(!lock.canEnable && !lock.enabled)
                }
            }
        }
    }
}

struct ProxySettingsGroup: View {
    @Environment(AppSettings.self) private var settings
    @State private var port = ""

    var body: some View {
        @Bindable var s = settings
        SettingsGroup(title: "Proxy", footer: "Sends playlist, guide, artwork and detail requests, and streams played by the MPV engine, through a proxy. MPV supports HTTP proxies only. Apple's player uses the system network settings and ignores this.") {
            SettingsRow(title: "Type", detail: s.proxy.isActive ? "On" : "Off") {
                Picker("", selection: $s.proxyKind) { ForEach(ProxyConfig.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
            }
            if s.proxyKind != .off {
                SettingsRow(title: "Address", detail: "Host name or IP address, and port.") {
                    HStack {
                        TextField("host", text: $s.proxyHost).textFieldStyle(.roundedBorder).frame(width: 180)
                        TextField("port", text: $port).textFieldStyle(.roundedBorder).frame(width: 70)
                            .onChange(of: port) { _, v in s.proxyPort = Int(v.filter(\.isNumber)) ?? 0 }
                    }
                }
            }
        }
        .onAppear { port = s.proxyPort > 0 ? String(s.proxyPort) : "" }
    }
}

struct VPNSettingsGroup: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsGroup(title: "VPN", footer: "StreamSetu does not run a VPN and never sees what your VPN does. It only looks for a VPN connection on this Mac; it cannot confirm that StreamSetu's traffic goes through it. The option below pauses playback when a detected VPN drops, which helps keep a stream from carrying on outside it but is not a guarantee.") {
            SettingsRow(title: "Status", detail: (container?.vpn.isOn ?? false) ? "A VPN connection is detected." : "No VPN connection detected.") {
                Button("Open Network Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!) }
            }
            SettingsRow(title: "Pause if the VPN drops", detail: "Only while something is playing.") {
                Toggle("", isOn: $s.vpnPause).labelsHidden()
            }
        }
    }
}
