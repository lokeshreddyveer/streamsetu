import SwiftUI
import UniformTypeIdentifiers

/// Adds an M3U link, an M3U file from Files, or an Xtream login. A link or file opened from outside only fills the form in.
struct AddPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @State private var vm = AddSourceViewModel()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $vm.kind) { ForEach(AddSourceKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                }.listRowBackground(ColorTokens.surface)
                Section {
                    TextField("Name (optional)", text: $vm.name).textInputAutocapitalization(.words)
                    switch vm.kind {
                    case .stalker:
                        TextField("Portal address (http://host/c/)", text: $vm.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("MAC address (00:1A:79:XX:XX:XX)", text: $vm.username).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    case .hdhomerun:
                        TextField("Tuner address (192.168.1.50)", text: $vm.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    case .plex:
                        TextField("Server address (http://host:32400)", text: $vm.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Access token", text: $vm.password)
                    case .xtream, .jellyfin, .emby, .tvheadend:
                        TextField(vm.kind == .xtream ? "Server (http://host:port)" : (vm.kind == .tvheadend ? "Server (http://host:9981)" : "Server (http://host:8096)"), text: $vm.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $vm.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $vm.password)
                    case .m3uURL:
                        TextField("Playlist address", text: $vm.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    case .m3uFile:
                        Button { importing = true } label: { Label(vm.fileURL?.lastPathComponent ?? "Choose a file…", systemImage: "doc") }
                    }
                } footer: {
                    Text("Only add playlists and accounts you are allowed to use. Logins are kept in the device Keychain.")
                }.listRowBackground(ColorTokens.surface)
                if let error = vm.error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }.listRowBackground(ColorTokens.surface) }
            }
            .navigationTitle("Add Playlist").themed("Add Playlist")
            .navigationBarTitleDisplayMode(.inline).clearTopBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isWorking { ProgressView() } else { Button("Add") { add() }.disabled(!vm.canSubmit) }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "m3u") ?? .data, UTType(filenameExtension: "m3u8") ?? .data, .json]) { result in
                guard case .success(let url) = result else { return }
                pick(url)
            }
            .onAppear(perform: applyPending)
            .interactiveDismissDisabled(vm.isWorking)
        }
    }

    private func add() {
        guard let container else { return }
        Task {
            if await vm.submit(container: container) != nil { state.reload(); router.pendingAdd = nil; dismiss() }
        }
    }

    /// Files from the picker are only readable inside a security scope, so copy the file into the app's own folder first.
    private func pick(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            vm.fileURL = dest
            if vm.name.isEmpty { vm.name = url.deletingPathExtension().lastPathComponent }
        } catch { vm.error = "That file could not be read." }
    }

    private func applyPending() {
        guard let p = router.pendingAdd else { return }
        switch p {
        case .address(let address, let name):
            vm.kind = .m3uURL; vm.url = address; if let name { vm.name = name }
        case .file(let url):
            vm.kind = .m3uFile; pick(url)
        }
    }
}
