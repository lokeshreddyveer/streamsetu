import SwiftUI

/// A PIN field that only accepts digits.
struct PINField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        SecureField(title, text: $text).keyboardType(.numberPad).textContentType(.oneTimeCode)
            .onChange(of: text) { _, v in text = String(v.filter(\.isNumber).prefix(8)) }
    }
}

/// Asks for the PIN to show locked folders for a while. Used wherever a locked folder is opened.
struct UnlockSheet: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    var onUnlocked: () -> Void = {}
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PINField(title: "PIN", text: $pin)
                    if let error { Label(error, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange).font(.callout) }
                } footer: { Text("Locked folders show for \(container?.parental.unlockMinutes ?? 15) minutes, then lock again by themselves, or when you leave the app.") }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Unlock Folders").themed("Unlock Folders").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Unlock") { unlock() }.disabled(pin.count < 4) }
            }
        }
        .presentationDetents([.medium])
    }

    private func unlock() {
        guard let p = container?.parental else { return }
        switch p.unlock(pin: pin) {
        case .unlocked, .noPIN: dismiss(); onUnlocked()
        case .wrongPIN(let n): error = "That isn't the PIN. \(n) tries left."; pin = ""
        case .tooManyAttempts(let t): error = "Too many tries. Wait \(Int(t.rounded(.up))) seconds."; pin = ""
        }
    }
}

struct ParentalView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var showSet = false
    @State private var showUnlock = false
    @State private var showRemove = false
    @State private var folders: [(kind: ContentKind, items: [CatalogCategory])] = []
    @State private var tick = 0

    var body: some View {
        let p = container?.parental
        List {
            if let lock = container?.appLock {
                Section {
                    Toggle("Require \(lock.method)", isOn: Binding(get: { lock.enabled }, set: { v in Task { await lock.setEnabled(v) } })).disabled(!lock.canEnable && !lock.enabled)
                } header: { Text("App Lock") } footer: {
                    Text(lock.canEnable ? "Locks StreamSetu when you leave it for more than 30 seconds. A stream that is playing keeps playing." : "Set a passcode on this device to use App Lock.")
                }.listRowBackground(ColorTokens.surface)
            }
            Section {
                if p?.hasPIN == true {
                    Button("Change PIN") { showSet = true }
                    Button("Remove PIN", role: .destructive) { showRemove = true }
                } else {
                    Button("Set a PIN") { showSet = true }
                }
            } header: { Text("PIN") } footer: {
                Text("Four to eight digits, stored on this device as a salted hash. It keeps casual viewers out of locked folders; it isn't protection against someone who can open this device's files.")
            }.listRowBackground(ColorTokens.surface)
            if let p, p.hasPIN {
                Section("Right now") {
                    LabeledContent("Locked folders", value: p.isUnlocked ? "Visible" : "Hidden")
                    if p.isUnlocked { Button("Lock Now") { p.lockNow(); tick += 1 } } else { Button("Unlock…") { showUnlock = true } }
                    Stepper("Unlock lasts \(p.unlockMinutes) min", value: Binding(get: { p.unlockMinutes }, set: { p.unlockMinutes = $0; tick += 1 }), in: 1...240, step: 5)
                }.listRowBackground(ColorTokens.surface)
                if p.isUnlocked {
                    ForEach(folders, id: \.kind) { group in
                        Section(title(group.kind)) {
                            ForEach(group.items) { c in
                                Toggle(c.name, isOn: Binding(get: { p.isLocked(c.id) }, set: { _ = p.setFolder(c.id, locked: $0); tick += 1 }))
                            }
                        }.listRowBackground(ColorTokens.surface)
                    }
                } else {
                    Section { Text("Unlock to choose which folders are locked.").font(.callout).foregroundStyle(.secondary) }.listRowBackground(ColorTokens.surface)
                }
            }
        }
        .id(tick)
        .navigationTitle("Parental Controls").themed("Parental Controls")
        .sheet(isPresented: $showSet) { SetPINSheet(changing: p?.hasPIN == true) { tick += 1 } }
        .sheet(isPresented: $showUnlock) { UnlockSheet { tick += 1; Task { await load() } } }
        .sheet(isPresented: $showRemove) { RemovePINSheet { tick += 1 } }
        .task(id: tick) { await load() }
    }

    private func title(_ k: ContentKind) -> String { k == .channel ? "Live TV folders" : k == .movie ? "Movie folders" : "Series folders" }

    private func load() async {
        guard let c = container else { return }
        let source = state.activeSourceID
        let all = await Task.detached { () -> [(ContentKind, [CatalogCategory])] in
            [ContentKind.channel, .movie, .series].map { ($0, (try? c.catalog.categories(sourceID: source, kind: $0, includeHidden: true)) ?? []) }
        }.value
        folders = all.filter { !$0.1.isEmpty }.map { (kind: $0.0, items: $0.1) }
    }
}

private struct SetPINSheet: View {
    let changing: Bool
    var done: () -> Void
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var again = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if changing { PINField(title: "Current PIN", text: $current) }
                    PINField(title: "New PIN (4–8 digits)", text: $new)
                    PINField(title: "Repeat new PIN", text: $again)
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle(changing ? "Change PIN" : "Set PIN").themed(changing ? "Change PIN" : "Set PIN").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(new.count < 4) }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard new == again else { error = "The two PINs don't match."; return }
        if container?.parental.setPIN(new, current: changing ? current : nil) == true { done(); dismiss() }
        else { error = changing ? "The current PIN isn't right." : "That PIN couldn't be saved." }
    }
}

private struct RemovePINSheet: View {
    var done: () -> Void
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PINField(title: "PIN", text: $pin)
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                } footer: { Text("Folder locks are kept, but nothing is hidden without a PIN.") }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Remove PIN").themed("Remove PIN").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) { Button("Remove", role: .destructive) { remove() }.disabled(pin.count < 4) }
            }
        }
        .presentationDetents([.medium])
    }

    private func remove() {
        if container?.parental.removePIN(current: pin) == true { done(); dismiss() } else { error = "That isn't the PIN."; pin = "" }
    }
}
