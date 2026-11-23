import SwiftUI
import UniformTypeIdentifiers

/// Adds a playlist link or file, a login, a media server, a tuner, a portal or a single stream. Two steps: first one field that takes
/// any address and the tiles for each way to connect, then the form for the chosen type. A tile or paste on the welcome screen, and a
/// link or file opened from outside, start on the form. A link or file opened from outside only fills the form in.
struct AddPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vm = AddSourceViewModel()
    @State private var importing = false
    @State private var pasted = ""
    @State private var finder = HDHomeRunDiscovery()
    @State private var askAboutHTTP = false
    @State private var step = Step.choose
    @FocusState private var focus: Field?
    /// Haptics: a light tap when Connect is pressed, then success or error when the connection is made or fails.
    @State private var connects = 0
    @State private var outcome: (count: Int, ok: Bool) = (0, true)
    /// Failures so far: each one shakes the form card once.
    @State private var shakes: CGFloat = 0
    /// True for the moment between a connection being made and the sheet closing, while the check is drawn.
    @State private var connected = false
    @State private var headerPlay = 0
    /// Opened from the first-run welcome (no playlist yet): the sheet keeps the welcome's brand colours. Opened from inside the app
    /// it follows the active theme. Decided once, when the sheet opens, so it does not change colour as the first playlist arrives.
    @State private var fromWelcome: Bool?
    private var palette: StartPalette { (fromWelcome ?? state.needsOnboarding) ? .brand : .theme }

    private enum Step { case choose, form }
    private enum Field: Hashable { case name, address, user, secret }

    /// The tile the form belongs to follows the type, so a paste that is taken for a media server shows the media server form.
    private var tile: StartTile { StartTile.tile(for: vm.kind) }

    var body: some View {
        NavigationStack {
            ZStack {
                StartBackdrop(glowAt: UnitPoint(x: 0.5, y: 0.05))
                switch step {
                case .choose: chooser.transition(moveTransition(from: .leading))
                case .form: form.transition(moveTransition(from: .trailing))
                }
                if connected {
                    palette.base.opacity(0.55).ignoresSafeArea().transition(.opacity)
                    ConnectedMark(color: palette.focus).transition(.opacity)
                }
            }
            .environment(\.startPalette, palette)
            .themed("Add Playlist").atlasScreen("screen.ios.addPlaylist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if step == .form {
                    ToolbarItem(placement: .confirmationAction) {
                        if vm.isWorking { DotWave(color: palette.text).accessibilityLabel("Connecting") } else { Button("Connect", action: connect).disabled(!vm.canSubmit).atlas("control.ios.addPlaylist.connect") }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "m3u") ?? .data, UTType(filenameExtension: "m3u8") ?? .data, .json]) { result in
                guard case .success(let url) = result else { return }
                pick(url)
            }
            .alert("This server is not encrypted", isPresented: $askAboutHTTP) {
                Button("Save Anyway") { vm.acceptPlainHTTP(); add() }.atlas("control.ios.addPlaylist.saveAnyway")
                Button("Cancel", role: .cancel) {}
            } message: { Text(vm.plainHTTPWarning ?? "") }
            .onAppear { if fromWelcome == nil { fromWelcome = state.needsOnboarding }; applyPending() }
            .interactiveDismissDisabled(vm.isWorking || connected)
            .sensoryFeedback(.impact(weight: .light), trigger: connects)
            .sensoryFeedback(trigger: outcome.count) { outcome.ok ? .success : .error }
        }
    }

    // MARK: Step 1: paste or choose a type

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StartPasteField(text: $pasted, note: vm.detectionNote, canSubmit: SourceDetector.detect(pasted) != nil) { go(.form) }
                    .startRise(order: 0)
                Text("Or choose how you connect").appFont(15, .semibold).foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 28).padding(.bottom, 12)
                    .startRise(order: 1)
                StartTileGrid(pick: choose)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: pasted) { _, v in vm.paste(v) }
    }

    private func choose(_ tile: StartTile) {
        if !tile.kinds.contains(vm.kind), let first = tile.kinds.first { vm.kind = first }
        go(.form)
    }

    // MARK: Step 2: the form for one type

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { go(.choose) } label: {
                    Label("All connection types", systemImage: "chevron.left").appFont(15, .medium).foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.borderless)
                .atlas("control.ios.addPlaylist.back")
                header
                if tile.kinds.count > 1 {
                    StartSegments(items: tile.kinds, selection: $vm.kind) { $0.rawValue.replacingOccurrences(of: " receiver", with: "") }
                }
                VStack(alignment: .leading, spacing: 16) { fields }
                    .padding(16)
                    .startSurface()
                    .modifier(Shake(shakes: shakes))
                Text("Only add playlists and accounts you are allowed to use. Logins are kept in the device Keychain.")
                    .appFont(13).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(ColorTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                Button(action: connect) {
                    HStack(spacing: 10) {
                        if vm.isWorking { DotWave() }
                        Text(vm.isWorking ? "Connecting…" : "Connect")
                    }
                }
                .buttonStyle(StartPrimaryStyle(busy: vm.isWorking))
                .disabled(!vm.canSubmit || vm.isWorking)
                .atlas("control.ios.addPlaylist.connect")
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.82), value: vm.error)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
            .startRise()
            .id(tile)          // a different type rises in afresh
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack(spacing: 14) {
            StartIconBadge(symbol: tile.symbol, size: 48, trigger: headerPlay)
                .task(id: tile) {          // the icon plays once as its form opens
                    guard !reduceMotion else { return }
                    try? await Task.sleep(for: .milliseconds(350)); headerPlay += 1
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect \(tile.title)").appFont(24, .bold).tracking(-0.3).foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(tile.subtitle).appFont(15).foregroundStyle(palette.textSecondary)
            }
        }
    }

    @ViewBuilder private var fields: some View {
        labelled("Name", .name) { TextField("Name (optional)", text: $vm.name).textInputAutocapitalization(.words).focused($focus, equals: .name) }
        switch vm.kind {
        case .stalker:
            labelled("Portal address", .address) { address("Portal address (http://host/c/)", $vm.server) }
            labelled("MAC address", .user) { TextField("MAC address (00:1A:79:XX:XX:XX)", text: $vm.username).textInputAutocapitalization(.characters).autocorrectionDisabled().focused($focus, equals: .user) }
        case .stream:
            labelled("Stream address", .address) { address("Stream address (https://, rtsp://, udp://, srt://)", $vm.url) }
        case .hdhomerun:
            labelled("Tuner address", .address) { address("Tuner address (192.168.1.50)", $vm.server) }
            Button { finder.start() } label: {
                HStack(spacing: 8) {
                    if finder.searching { ProgressView().tint(palette.text) }
                    Label(finder.searching ? "Looking…" : "Find Tuners on This Network", systemImage: "dot.radiowaves.left.and.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(StartSecondaryStyle()).disabled(finder.searching)
            .atlas("control.ios.addPlaylist.findTuners")
            ForEach(finder.tuners) { t in
                Button { vm.server = t.host; if vm.name.isEmpty { vm.name = t.name } } label: {
                    Label("\(t.name) · \(t.host)", systemImage: "tv.and.mediabox").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(StartSecondaryStyle())
                .atlas("control.ios.addPlaylist.pickTuner")
            }
        case .plex:
            labelled("Server address", .address) { address("Server address (http://host:32400)", $vm.server) }
            labelled("Access token", .secret) { SecureField("Access token", text: $vm.password).focused($focus, equals: .secret) }
        case .xtream, .jellyfin, .emby, .tvheadend, .enigma2:
            labelled(vm.kind == .enigma2 ? "Receiver" : "Server", .address) {
                address(vm.kind == .xtream ? "Server (http://host:port)" : (vm.kind == .tvheadend ? "Server (http://host:9981)" : (vm.kind == .enigma2 ? "Receiver (http://receiver-ip)" : "Server (http://host:8096)")), $vm.server)
            }
            labelled("User name", .user) { TextField("Username", text: $vm.username).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: .user) }
            labelled("Password", .secret) { SecureField("Password", text: $vm.password).focused($focus, equals: .secret) }
        case .m3uURL:
            labelled("Playlist address", .address) { address("Playlist address", $vm.url) }
        case .m3uFile:
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("File")
                Button { importing = true } label: {
                    Label(vm.fileURL?.lastPathComponent ?? "Choose a file…", systemImage: "doc").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(StartSecondaryStyle())
                .atlas("control.ios.addPlaylist.chooseFile")
            }
        }
    }

    /// An address field: a URL keyboard, no capitals, no corrections.
    private func address(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: .address)
    }

    private func fieldLabel(_ text: String, lit: Bool = false) -> some View {
        Text(text).appFont(13, .semibold).foregroundStyle(lit ? palette.text : palette.textSecondary).accessibilityHidden(true)
    }

    /// A label above its field, and the field in a slightly darker well. While it is typed in, the hairline turns to the focus colour and
    /// the label brightens and lifts a little. The label is also the field's name for VoiceOver.
    private func labelled<F: View>(_ label: String, _ id: Field, @ViewBuilder field: () -> F) -> some View {
        let lit = focus == id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label, lit: lit).offset(y: lit && !reduceMotion ? -1 : 0)
            field()
                .appFont(16).foregroundStyle(palette.text)
                .padding(.horizontal, 12).frame(minHeight: 46)
                .background(shape.fill(palette.well))
                .overlay(shape.strokeBorder(lit ? palette.focus.opacity(0.8) : palette.hairline, lineWidth: lit ? 1.5 : 1))
                .accessibilityLabel(label)
        }
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    // MARK: Actions

    /// A short crossfade with a 12 pt slide in the direction of travel.
    private func moveTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .offset(x: edge == .trailing ? 12 : -12).combined(with: .opacity), removal: .opacity)
    }

    private func go(_ next: Step) {
        focus = nil
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32)) { step = next }
    }

    private func connect() {
        connects += 1
        if vm.plainHTTPWarning != nil { askAboutHTTP = true } else { add() }
    }

    private func add() {
        guard let container else { return }
        Task {
            let added = await vm.submit(container: container) != nil
            outcome = (outcome.count + 1, added)
            guard added else {
                if !reduceMotion { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
                return
            }
            // The check draws itself, then the sheet closes.
            withAnimation(.easeOut(duration: 0.2)) { connected = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 500 : 900))
            state.reload(); router.pendingAdd = nil; dismiss()
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

    /// A tile or paste on the welcome screen comes first (it was just chosen); otherwise a link or file opened from outside fills the
    /// form in. Either way the sheet opens on the form, without the step change being animated.
    private func applyPending() {
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) {
            if let preset = router.addPreset {
                router.addPreset = nil
                switch preset {
                case .kind(let kind): vm.kind = kind
                case .pasted(let text): pasted = text; vm.paste(text)
                }
                step = .form
                return
            }
            guard let p = router.pendingAdd else { return }
            switch p {
            case .address(let address, let name):
                vm.kind = .m3uURL; vm.url = address; if let name { vm.name = name }
            case .file(let url):
                vm.kind = .m3uFile; pick(url)
            }
            step = .form
        }
    }
}
