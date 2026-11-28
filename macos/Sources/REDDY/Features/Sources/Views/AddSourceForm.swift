import SwiftUI

/// Shared by onboarding and the Add Source sheet. It opens on the ways to connect (a paste field and the tiles); choosing a tile,
/// or pasting an address and pressing Return, shows the fields for that kind. Going back to the tiles keeps what was typed.
struct AddSourceForm<ChooserFooter: View>: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var vm = AddSourceViewModel()
    @State private var pasted = ""
    @State private var finder = HDHomeRunDiscovery()
    @State private var askAboutHTTP = false
    /// The tile being filled in; nil while the tiles are shown.
    @State private var tile: ConnectionTile?
    @State private var pasteHovering = false
    @FocusState private var pasteFocused: Bool
    @FocusState private var focusedField: String?
    @Environment(\.startBranded) private var branded
    @Environment(\.startMotion) private var motion
    @Environment(\.reddyAccent) private var accent
    /// Counts failed attempts; each one shakes the form card once.
    @State private var failures: CGFloat = 0
    private let onAdded: (PlaylistSource) -> Void
    /// Extra actions shown under the tiles only (the welcome screen puts Restore from iCloud here).
    private let chooserFooter: () -> ChooserFooter

    /// When set (the Add Source sheet), the tiles or fields scroll inside this height and the buttons and legal line stay pinned
    /// below them, always visible. When nil (the welcome screen, which scrolls as a whole), everything is laid out in one column.
    private let scrollHeight: CGFloat?
    @State private var contentHeight: CGFloat = 400

    init(scrollHeight: CGFloat? = nil, onAdded: @escaping (PlaylistSource) -> Void, @ViewBuilder chooserFooter: @escaping () -> ChooserFooter) {
        self.scrollHeight = scrollHeight
        self.onAdded = onAdded
        self.chooserFooter = chooserFooter
    }

    var body: some View {
        Group {
            if let scrollHeight {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.vertical) {
                        // Padded inside the scroll view (and pulled back out below), so button edges and focus rings are
                        // never cut off at the sides.
                        content.padding(.horizontal, 22).padding(.bottom, 6)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(contentHeight, scrollHeight))
                    // When it scrolls, the last lines fade out above the pinned buttons instead of ending at a hard edge.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: contentHeight > scrollHeight ? 0.9 : 1),
                                                 .init(color: .black.opacity(contentHeight > scrollHeight ? 0.15 : 1), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    footer.padding(.horizontal, 22)
                }
                .padding(.horizontal, -22)
            } else {
                VStack(alignment: .leading, spacing: 0) { content; footer }
            }
        }
        .onAppear { applyPending() }
        .onChange(of: router.pendingAdd) { _, _ in applyPending() }
    }

    @ViewBuilder private var content: some View {
        if let tile { form(for: tile).id(tile.id) } else { chooser }
    }

    /// The form's error and buttons (when a tile is open) and the legal line. In the sheet these stay pinned below the scrolling part.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tile != nil, let e = vm.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(Typography.row).foregroundStyle(ColorTokens.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, Spacing.md)
                    .transition(motion ? .move(edge: .top).combined(with: .opacity) : .opacity)
            }
            if tile != nil { actionRow.padding(.top, Spacing.lg) }
            Text("StreamSetu is a player for services you are authorized to use.")
                .font(Typography.caption).foregroundStyle(StartStyle.textTertiary(branded))
                .padding(.top, Spacing.lg)
        }
        .animation(motion ? .easeOut(duration: 0.25) : nil, value: vm.error)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if AssistantFeature.isOn {
                SecondaryButton(title: "Help me with this", symbol: "sparkles") {
                    AssistantLauncher.shared.ask("How do I add a \(vm.kind.rawValue) source? What do I fill in?"); AssistantLauncher.bringMainWindowForward()
                }.atlas("screen.addPlaylist")
            }
            Spacer()
            Button { if vm.plainHTTPWarning != nil { askAboutHTTP = true } else { submitNow() } } label: {
                HStack(spacing: 8) {
                    if vm.isWorking { StartBusyRing() }
                    Text(vm.isWorking ? "Connecting…" : "Connect")
                }
            }
            .buttonStyle(StartPrimaryButtonStyle(busy: vm.isWorking))
            .keyboardShortcut(.defaultAction)
            .disabled(!vm.canSubmit || vm.isWorking)
            .alert("This server is not encrypted", isPresented: $askAboutHTTP) {
                Button("Save Anyway") { vm.acceptPlainHTTP(); submitNow() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(vm.plainHTTPWarning ?? "") }.atlas("screen.addPlaylist")
        }
        .startRiseIn(delay: 0.09)
    }

    // MARK: The ways to connect

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            pasteField.startRiseIn()
            pasteNote.padding(.top, 10).padding(.horizontal, 4).startRiseIn(delay: 0.04)
            Text("Or choose how you connect").font(.system(size: 12, weight: .semibold)).foregroundStyle(StartStyle.textSecondary(branded))
                .padding(.top, Spacing.xxl).padding(.bottom, 10).padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .startRiseIn(delay: 0.06)
            ConnectionTileGrid { open($0) }
            chooserFooter()
        }
    }

    private var pasteField: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .medium)).foregroundStyle(StartStyle.glow(branded, accent: accent)).accessibilityHidden(true)
            TextField("Paste a playlist link, server address or stream", text: $pasted)
                .textFieldStyle(.plain).font(.system(size: 15)).autocorrectionDisabled()
                .focused($pasteFocused)
                .onChange(of: pasted) { _, v in vm.paste(v) }
                .onSubmit { continueFromPaste() }
            SecondaryButton(title: "Paste", symbol: "doc.on.clipboard") {
                if let t = NSPasteboard.general.string(forType: .string) { pasted = t }
            }.atlas("screen.addPlaylist")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .frame(minHeight: 54)
        .startSurface(hovered: pasteHovering || pasteFocused)
        .onHover { pasteHovering = $0 }
    }

    /// Says what the pasted address was taken for, with a way to go on to its form; before anything is pasted, says what the field does.
    @ViewBuilder private var pasteNote: some View {
        if let note = vm.detectionNote {
            HStack(spacing: 10) {
                Label(note, systemImage: canContinueFromPaste ? "checkmark.circle" : "questionmark.circle")
                    .font(Typography.row).foregroundStyle(StartStyle.textSecondary(branded)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if canContinueFromPaste {
                    SecondaryButton(title: "Continue", symbol: "arrow.right") { continueFromPaste() }.atlas("screen.addPlaylist")
                }
            }
        } else {
            Text("StreamSetu works out the type and fills in the rest.").font(Typography.row).foregroundStyle(StartStyle.textSecondary(branded))
        }
    }

    private var canContinueFromPaste: Bool { SourceDetector.detect(pasted) != nil }

    private func continueFromPaste() {
        guard canContinueFromPaste else { return }
        open(ConnectionTile.tile(for: vm.kind))
    }

    /// Shows a tile's fields. The kind already chosen is kept when the tile covers it, so a pasted Jellyfin address stays Jellyfin.
    private func open(_ chosen: ConnectionTile) {
        if !chosen.kinds.contains(vm.kind) { vm.kind = chosen.kinds[0] }
        tile = chosen
    }

    // MARK: The form for one tile

    private func form(for tile: ConnectionTile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { self.tile = nil } label: {
                Label("All connection types", systemImage: "chevron.left").font(Typography.rowMedium).foregroundStyle(StartStyle.textSecondary(branded))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("All connection types"))
            .startRiseIn().atlas("screen.addPlaylist")

            HStack(alignment: .center, spacing: 14) {
                StartIconTile(symbol: tile.symbol, size: 48, motionKind: tile.iconMotion, trigger: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect \(tile.title)").font(.system(size: 22, weight: .bold)).tracking(-0.3).foregroundStyle(StartStyle.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(tile.subtitle.loc).font(Typography.body).foregroundStyle(StartStyle.textSecondary(branded))
                }
            }
            .padding(.top, Spacing.lg)
            .startRiseIn(delay: 0.03)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                if tile.kinds.count > 1 {
                    StartSegmented(items: tile.kinds, selection: $vm.kind) { $0.rawValue }
                }
                fields
                field("Name (optional)", text: $vm.name, prompt: "My IPTV")
                Label("Logins are stored encrypted on this Mac, never in the library database.", systemImage: "lock.shield")
                    .font(Typography.caption).foregroundStyle(StartStyle.textSecondary(branded)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
            .startSurface()
            .modifier(StartShake(animatableData: failures))
            .padding(.top, Spacing.xl)
            .startRiseIn(delay: 0.06)
        }
    }

    /// The fields for the chosen kind, with the same labels and placeholders as before.
    @ViewBuilder private var fields: some View {
        switch vm.kind {
        case .stalker:
            field("Portal address", text: $vm.server, prompt: "http://host/c/")
            field("MAC address", text: $vm.username, prompt: "00:1A:79:XX:XX:XX")
        case .stream:
            field("Stream address", text: $vm.url, prompt: "https://host/live.ts, .m3u8, rtsp://, udp://, srt://")
        case .hdhomerun:
            field("Tuner address", text: $vm.server, prompt: "192.168.1.50 or hdhomerun.local")
            HStack(spacing: 8) {
                SecondaryButton(title: finder.searching ? "Looking…" : "Find Tuners on This Network", symbol: "dot.radiowaves.left.and.right") { finder.start() }.disabled(finder.searching).atlas("screen.addPlaylist")
                if finder.searching { ProgressView().controlSize(.small) }
            }
            ForEach(finder.tuners) { t in
                Button { vm.server = t.host; if vm.name.isEmpty { vm.name = t.name } } label: {
                    Label("\(t.name)  ·  \(t.host)", systemImage: "tv.and.mediabox").foregroundStyle(StartStyle.textPrimary)
                }.buttonStyle(.plain).atlas("screen.addPlaylist")
            }
        case .plex:
            field("Server address", text: $vm.server, prompt: "http://host:32400")
            field("Access token", text: $vm.password, prompt: "X-Plex-Token", secure: true)
        case .xtream, .jellyfin, .emby, .tvheadend, .enigma2:
            field("Server", text: $vm.server, prompt: vm.kind == .xtream ? "http://host:port" : (vm.kind == .tvheadend ? "http://host:9981" : (vm.kind == .enigma2 ? "http://receiver-ip" : "http://host:8096")))
            field("Username", text: $vm.username, prompt: "username")
            field("Password", text: $vm.password, prompt: "password", secure: true)
        case .m3uURL:
            field("Playlist address", text: $vm.url, prompt: "https://example.com/playlist.m3u")
        case .m3uFile:
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Playlist file").foregroundStyle(StartStyle.textSecondary(branded))
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(StartStyle.textSecondary(branded)).accessibilityHidden(true)
                    Text(vm.fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(vm.fileURL == nil ? StartStyle.textSecondary(branded) : StartStyle.textPrimary).lineLimit(1)
                    Spacer()
                    SecondaryButton(title: "Choose File…", symbol: "doc") { vm.chooseFile() }.atlas("screen.addPlaylist")
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(fieldShape.fill(StartStyle.fieldFill(branded)))
                .overlay(fieldShape.strokeBorder(StartStyle.surfaceEdge(branded)))
            }
        }
    }

    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private func fieldLabel(_ title: String) -> some View {
        Text(title.loc).font(Typography.captionMedium)
    }

    /// A labelled field. Secure fields stay secure. On focus the hairline takes the glow colour and the label lifts and brightens.
    private func field(_ title: String, text: Binding<String>, prompt: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
                .foregroundStyle(focusedField == title ? StartStyle.textPrimary : StartStyle.textSecondary(branded))
                .offset(y: focusedField == title && motion ? -1 : 0)
            Group {
                if secure { SecureField(prompt, text: text) } else { TextField(prompt, text: text).autocorrectionDisabled() }
            }
            .textFieldStyle(.plain).font(.system(size: 14))
            .focused($focusedField, equals: title)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(fieldShape.fill(StartStyle.fieldFill(branded)))
            .overlay(fieldShape.strokeBorder(focusedField == title ? StartStyle.glow(branded, accent: accent).opacity(0.7) : StartStyle.surfaceEdge(branded)))
        }
        .animation(.easeOut(duration: 0.15), value: focusedField)
    }

    // MARK: Saving and links

    private func submitNow() {
        guard let container else { return }
        Task {
            if let s = await vm.submit(container: container) { state.reload(); onAdded(s) }
            else if vm.error != nil { withAnimation(motion ? .easeOut(duration: 0.45) : nil) { failures += 1 } }
        }
    }

    /// Fills the form from something dropped on the window or opened from a link, and shows its fields. The person still presses Connect.
    private func applyPending() {
        guard let p = router.pendingAdd else { return }
        switch p {
        case .address(let address, let name):
            vm.kind = .m3uURL; vm.url = address; if let name, vm.name.isEmpty { vm.name = name }
        case .file(let url):
            vm.kind = .m3uFile; vm.fileURL = url
        }
        router.pendingAdd = nil
        tile = ConnectionTile.tile(for: vm.kind)
    }
}

extension AddSourceForm where ChooserFooter == EmptyView {
    init(scrollHeight: CGFloat? = nil, onAdded: @escaping (PlaylistSource) -> Void = { _ in }) {
        self.init(scrollHeight: scrollHeight, onAdded: onAdded) { EmptyView() }
    }
}
