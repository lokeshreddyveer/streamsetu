import SwiftUI

/// Set once the person has chosen a profile in this run of the app, so the question is asked once at the start and not again.
enum ProfilePicked { @MainActor static var done = false }

private let profileColors: [Color] = [Color(red: 1.0, green: 0.42, blue: 0.24), Color(red: 0.25, green: 0.62, blue: 0.95), Color(red: 0.36, green: 0.78, blue: 0.50), Color(red: 0.72, green: 0.45, blue: 0.95), Color(red: 0.95, green: 0.70, blue: 0.20), Color(red: 0.90, green: 0.38, blue: 0.62)]

struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 88
    var body: some View {
        ZStack {
            Circle().fill(profileColors[abs(profile.color) % profileColors.count].gradient)
            Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            if profile.kind == .kids { Image(systemName: "face.smiling.inverse").font(.system(size: size * 0.2)).foregroundStyle(.white).padding(5).background(.black.opacity(0.45), in: Circle()).offset(x: size * 0.34, y: size * 0.34) }
        }
        .frame(width: size, height: size)
    }
}

/// "Who's watching?": shown at the start when more than one profile exists.
struct ProfilePicker: View {
    let service: ProfileService
    let onDone: () -> Void
    @State private var asking: Profile?
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        ZStack {
            ColorTokens.background.ignoresSafeArea()
            VStack(spacing: 28) {
                Text(asking == nil ? "Who's watching?" : (service.leavingNeedsPIN ? "Enter \(service.active.name)'s PIN to leave" : "Enter the PIN for \(asking!.name)")).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                if let p = asking {
                    ProfileAvatar(profile: p, size: 84)
                    SecureField("PIN", text: $pin).textFieldStyle(.roundedBorder).frame(width: 160).multilineTextAlignment(.center)
                        .onSubmit { try_(p) }
                    if wrong { Text("That PIN is not right.").foregroundStyle(.red).font(.callout) }
                    HStack { Button("Back") { asking = nil; pin = ""; wrong = false }; Button("Continue") { try_(p) }.buttonStyle(.borderedProminent).disabled(pin.count < 4) }
                } else {
                    HStack(spacing: 28) {
                        ForEach(service.profiles) { p in
                            Button { choose(p) } label: {
                                VStack(spacing: 10) { ProfileAvatar(profile: p); Text(p.name).font(.system(size: 16, weight: .medium)); if p.hasPIN && p.kind == .adult { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) } }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: asking?.id)
        }
        .transition(.opacity)
    }

    private func choose(_ p: Profile) {
        if p.id == service.activeID { ProfilePicked.done = true; onDone(); return }
        if service.switchTo(p.id) == .needsPIN { asking = p; pin = ""; wrong = false } else { ProfilePicked.done = true; onDone() }
    }

    private func try_(_ p: Profile) {
        switch service.switchTo(p.id, pin: pin) {
        case .switched: ProfilePicked.done = true; onDone()
        default: wrong = true; pin = ""
        }
    }
}

/// Adds a profile.
struct AddProfileSheet: View {
    let service: ProfileService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kids = false
    @State private var usePIN = false
    @State private var pin = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New profile").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Kids profile", isOn: $kids)
            Text(kids ? "Folders you locked in Privacy stay hidden, and leaving this profile needs its PIN." : "").font(.caption).foregroundStyle(.secondary)
            if !kids { Toggle("Ask for a PIN to open this profile", isOn: $usePIN) }
            if kids || usePIN { SecureField("PIN (4 to 8 digits)", text: $pin).textFieldStyle(.roundedBorder) }
            if failed { Text("Check the name (it must be new) and the PIN (4 to 8 digits).").font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Add") { add() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(24).frame(minWidth: 320)
    }

    private func add() {
        if service.add(name: name, kind: kids ? .kids : .adult, pin: (kids || usePIN) ? pin : nil) != nil { dismiss() } else { failed = true }
    }
}

/// The profiles list for Settings: who is using the app, switching, adding and removing.
struct ProfilesList: View {
    let service: ProfileService
    @State private var adding = false
    @State private var askFor: Profile?
    @State private var pin = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(service.profiles) { p in
                HStack(spacing: 12) {
                    ProfileAvatar(profile: p, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.body.weight(.medium))
                        Text(p.id == service.activeID ? "In use now" : (p.kind == .kids ? "Kids" : (p.hasPIN ? "Has a PIN" : "Adult"))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.id != service.activeID {
                        Button("Switch") { tap(p) }
                        if p.id != ProfileService.mainID { Button("Remove", role: .destructive) { service.remove(p.id) } }
                    }
                }
            }
            if let p = askFor {
                HStack { SecureField("PIN for \(service.leavingNeedsPIN ? service.active.name : p.name)", text: $pin).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("OK") { go(p) }.disabled(pin.count < 4); Button("Cancel") { askFor = nil; pin = "" } }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Button { adding = true } label: { Label(service.canAdd ? "Add a Profile…" : "Four profiles is the most", systemImage: "plus") }.disabled(!service.canAdd)
        }
        .sheet(isPresented: $adding) { AddProfileSheet(service: service) }
    }

    private func tap(_ p: Profile) {
        message = nil
        if service.switchTo(p.id) == .needsPIN { askFor = p; pin = "" }
    }

    private func go(_ p: Profile) {
        switch service.switchTo(p.id, pin: pin) {
        case .switched: askFor = nil; pin = ""
        case .wrongPIN: message = "That PIN is not right."; pin = ""
        default: message = "Could not switch."
        }
    }
}
