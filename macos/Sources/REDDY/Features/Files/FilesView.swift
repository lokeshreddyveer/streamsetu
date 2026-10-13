import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Plays videos that are not from a playlist: a file from Files, a video from Photos, a folder on this device, or a WebDAV server.
struct FilesView: View {
    @Environment(\.container) private var container
    @State private var sources: [FileSource] = []
    @State private var pickingFile = false
    @State private var pickingFolder = false
    @State private var addingServer = false
    @State private var note: String?
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    private var store: FileSourceStore? { container.map { FileSourceStore(credentials: $0.credentials) } }

    var body: some View {
        List {
            Section {
                Button { pickingFile = true } label: { Label("Open a Video File", systemImage: "doc.badge.plus") }
                #if os(iOS)
                PhotosPicker(selection: $photo, matching: .videos) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
                #endif
            } footer: { Text("MP4, MKV, AVI, MOV and more. A subtitle file with the same name beside the video is used automatically.") }
            Section {
                ForEach(sources) { s in
                    NavigationLink { BrowserView(source: s) } label: {
                        Label { VStack(alignment: .leading) { Text(s.name); Text(s.kind == .webdav ? (s.address ?? "WebDAV") : "On this device").font(.caption).foregroundStyle(.secondary) } }
                        icon: { Image(systemName: s.kind == .webdav ? "server.rack" : "folder") }
                    }
                    .contextMenu { Button("Remove", role: .destructive) { remove(s) } }
                }
                .onDelete { idx in idx.map { sources[$0] }.forEach(remove) }
                Button { pickingFolder = true } label: { Label("Add a Folder", systemImage: "folder.badge.plus") }
                Button { addingServer = true } label: { Label("Add a WebDAV Server", systemImage: "externaldrive.badge.plus") }
            } header: { Text("Folders and Servers") } footer: { Text("WebDAV works with Nextcloud and most home servers (NAS). The password is kept in the Keychain.") }
            if let note { Section { Text(note).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Files and Servers")
        .onAppear { sources = store?.all() ?? [] }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.movie, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .item]) { result in
            guard case .success(let url) = result else { return }
            FilesPlayer.open(url, container: container)
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = FileSourceStore.bookmark(for: url) else { note = "That folder could not be saved."; return }
            store?.add(FileSource(kind: .folder, name: url.lastPathComponent, bookmark: data))
            sources = store?.all() ?? []
        }
        .sheet(isPresented: $addingServer) {
            AddServerForm { source, password in
                store?.add(source, password: password)
                sources = store?.all() ?? []
            }
        }
        #if os(iOS)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let picked = try? await item.loadTransferable(type: PickedVideo.self) { FilesPlayer.play(file: picked.url, title: "Video from Photos", container: container) }
                else { note = "That video could not be opened." }
                photo = nil
            }
        }
        #endif
    }

    private func remove(_ s: FileSource) { store?.remove(s); sources = store?.all() ?? [] }
}

#if os(iOS)
/// A video chosen in Photos, copied to a temporary place so the player can read it.
struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photos-pick", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)                           // the previous pick is not needed any more
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}
#endif

/// The one way every screen starts a file.
@MainActor enum FilesPlayer {
    static func open(_ url: URL, container: AppContainer?) {
        ScopedAccess.shared.holdOneOff(url)
        play(file: url, title: LocalMedia.title(fromFileName: url.lastPathComponent), subtitles: LocalMedia.sidecarURLs(for: url), container: container)
    }

    static func play(file: URL, title: String, headers: [String: String] = [:], subtitles: [URL] = [], container: AppContainer?) {
        guard let p = container?.playback else { return }
        p.play(file: file, title: title, headers: headers, subtitles: subtitles)
        p.isExpanded = true
    }
}

private struct AddServerForm: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (FileSource, String?) -> Void
    @State private var name = ""
    @State private var address = "https://"
    @State private var user = ""
    @State private var password = ""

    private var valid: Bool { URL(string: address)?.host != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name (for example Home NAS)", text: $name); TextField("Address (https://nas.local:5006/video)", text: $address)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                }
                Section("Login (if the server asks)") {
                    TextField("User name", text: $user)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("WebDAV Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(FileSource(kind: .webdav, name: name.trimmingCharacters(in: .whitespaces), address: address, username: user.isEmpty ? nil : user), password)
                        dismiss()
                    }.disabled(!valid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

/// A folder on this device or on a server: sub-folders open, a video plays.
struct BrowserView: View {
    @Environment(\.container) private var container
    let source: FileSource
    var location: URL?
    var title: String?
    @State private var entries: [MediaEntry] = []
    @State private var loading = true
    @State private var error: String?

    private var store: FileSourceStore? { container.map { FileSourceStore(credentials: $0.credentials) } }
    private var dav: WebDAVClient? {
        guard source.kind == .webdav, let a = source.address, let base = URL(string: a), let s = store else { return nil }
        return WebDAVClient(base: base, username: source.username, password: s.password(for: source))
    }
    private var root: URL? { source.kind == .webdav ? source.address.flatMap(URL.init(string:)) : store?.folderURL(source) }

    var body: some View {
        List {
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(entries.filter { $0.isFolder || LocalMedia.isVideo($0.name) }) { e in
                if e.isFolder {
                    NavigationLink { BrowserView(source: source, location: e.location, title: e.name) } label: { Label(e.name, systemImage: "folder") }
                } else {
                    Button { play(e) } label: {
                        HStack {
                            Label(LocalMedia.title(fromFileName: e.name), systemImage: "play.rectangle")
                            Spacer()
                            if let size = e.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !loading, error == nil, entries.isEmpty { Text("No videos or folders here.").foregroundStyle(.secondary) }
        }
        .navigationTitle(title ?? source.name)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let place = location ?? root else { error = "This folder is no longer available. Remove it and add it again."; loading = false; return }
        loading = true; error = nil
        do {
            entries = source.kind == .webdav ? try await (dav?.list(place) ?? []) : try MediaListing.local(place)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "This folder could not be opened." }
        loading = false
    }

    private func play(_ e: MediaEntry) {
        let names = entries.map(\.name)
        let subNames = LocalMedia.sidecars(of: e.name, among: names)
        let subEntries = entries.filter { subNames.contains($0.name) }
        let title = LocalMedia.title(fromFileName: e.name)
        let c = container
        if let dav {
            Task {
                var subs: [URL] = []
                for s in subEntries { if let f = await dav.download(s.location) { subs.append(f) } }
                FilesPlayer.play(file: e.location, title: title, headers: dav.headers, subtitles: subs, container: c)
            }
        } else {
            FilesPlayer.play(file: e.location, title: title, subtitles: subEntries.map(\.location), container: c)
        }
    }
}
