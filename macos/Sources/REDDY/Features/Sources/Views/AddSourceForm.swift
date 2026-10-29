import SwiftUI

/// Shared by onboarding and the Add Source sheet.
struct AddSourceForm: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var vm = AddSourceViewModel()
    @State private var pasted = ""
    @State private var finder = HDHomeRunDiscovery()
    @State private var askAboutHTTP = false
    var onAdded: (PlaylistSource) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: 8) {
                TextField("Paste any address and it fills in the rest", text: $pasted).textFieldStyle(.plain).padding(10)
                    .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border)).autocorrectionDisabled()
                    .onChange(of: pasted) { _, v in vm.paste(v) }
                SecondaryButton(title: "Paste", symbol: "doc.on.clipboard") {
                    if let t = NSPasteboard.general.string(forType: .string) { pasted = t }
                }
            }
            if let note = vm.detectionNote {
                Label(note, systemImage: "wand.and.stars").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Type", selection: $vm.kind) { ForEach(AddSourceKind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu)
            field("Name (optional)", text: $vm.name, prompt: "My IPTV")
            switch vm.kind {
            case .stalker:
                field("Portal address", text: $vm.server, prompt: "http://host/c/")
                field("MAC address", text: $vm.username, prompt: "00:1A:79:XX:XX:XX")
            case .stream:
                field("Stream address", text: $vm.url, prompt: "https://host/live.ts, .m3u8, rtsp://, udp://, srt://")
            case .hdhomerun:
                field("Tuner address", text: $vm.server, prompt: "192.168.1.50 or hdhomerun.local")
                HStack(spacing: 8) {
                    SecondaryButton(title: finder.searching ? "Looking…" : "Find Tuners on This Network", symbol: "dot.radiowaves.left.and.right") { finder.start() }.disabled(finder.searching)
                    if finder.searching { ProgressView().controlSize(.small) }
                }
                ForEach(finder.tuners) { t in
                    Button { vm.server = t.host; if vm.name.isEmpty { vm.name = t.name } } label: { Label("\(t.name)  ·  \(t.host)", systemImage: "tv.and.mediabox") }.buttonStyle(.plain)
                }
            case .plex:
                field("Server address", text: $vm.server, prompt: "http://host:32400")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Access token").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    SecureField("X-Plex-Token", text: $vm.password).textFieldStyle(.plain).padding(10).background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border))
                }
            case .xtream, .jellyfin, .emby, .tvheadend, .enigma2:
                field("Server", text: $vm.server, prompt: vm.kind == .xtream ? "http://host:port" : (vm.kind == .tvheadend ? "http://host:9981" : (vm.kind == .enigma2 ? "http://receiver-ip" : "http://host:8096")))
                field("Username", text: $vm.username, prompt: "username")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    SecureField("password", text: $vm.password).textFieldStyle(.plain).padding(10).background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border))
                }
            case .m3uURL:
                field("Playlist address", text: $vm.url, prompt: "https://example.com/playlist.m3u")
            case .m3uFile:
                HStack {
                    Text(vm.fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(vm.fileURL == nil ? ColorTokens.textSecondary : ColorTokens.textPrimary).lineLimit(1)
                    Spacer()
                    SecondaryButton(title: "Choose File…", symbol: "doc") { vm.chooseFile() }
                }.padding(10).background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border))
            }
            Label("Logins are stored encrypted on this Mac, never in the library database.", systemImage: "lock.shield")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            if let e = vm.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(Typography.caption).foregroundStyle(ColorTokens.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("StreamSetu is a player for services you are authorized to use.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                Button { AssistantLauncher.shared.ask("How do I add a \(vm.kind.rawValue) source? What do I fill in?"); AssistantLauncher.bringMainWindowForward() } label: { Label("Help me with this", systemImage: "sparkles") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if vm.isWorking { ProgressView().controlSize(.small) }
                PrimaryButton(title: vm.isWorking ? "Connecting…" : "Add Source", symbol: "plus") {
                    if vm.plainHTTPWarning != nil { askAboutHTTP = true } else { submitNow() }
                }.disabled(!vm.canSubmit || vm.isWorking)
                .alert("This server is not encrypted", isPresented: $askAboutHTTP) {
                    Button("Save Anyway") { vm.acceptPlainHTTP(); submitNow() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text(vm.plainHTTPWarning ?? "") }
            }
        }
        .onAppear { applyPending() }
        .onChange(of: router.pendingAdd) { _, _ in applyPending() }
    }

    /// Fills the form from something dropped on the window or opened from a link. The person still presses Add.
    private func submitNow() {
        guard let container else { return }
        Task { if let s = await vm.submit(container: container) { state.reload(); onAdded(s) } }
    }

    private func applyPending() {
        guard let p = router.pendingAdd else { return }
        switch p {
        case .address(let address, let name):
            vm.kind = .m3uURL; vm.url = address; if let name, vm.name.isEmpty { vm.name = name }
        case .file(let url):
            vm.kind = .m3uFile; vm.fileURL = url
        }
        router.pendingAdd = nil
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            TextField(prompt, text: text).textFieldStyle(.plain).padding(10)
                .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ColorTokens.border)).autocorrectionDisabled()
        }
    }
}

