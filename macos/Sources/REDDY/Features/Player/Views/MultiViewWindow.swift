import SwiftUI
import AVFoundation

/// Hosts one tile's AVPlayerLayer. The layer is sized in `layout()` with animations off, so a tile added while the grid is
/// animating never keeps a zero-size layer.
private final class TileVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct TileVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> TileVideoView { let v = TileVideoView(); v.playerLayer.player = player; return v }
    func updateNSView(_ v: TileVideoView, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player }; v.needsLayout = true }
}

/// Multi-view: up to four live channels at once, one audible. Channels are added, swapped and saved from inside this window.
struct MultiViewWindow: View {
    let model: MultiViewModel
    @Environment(\.reddyAccent) private var accent
    @State private var showPicker = false
    @State private var showSave = false
    @State private var presetName = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            if model.tiles.isEmpty { EmptyMultiView(add: { showPicker = true }, presets: model.presets, load: { model.load($0) }) }
            else if let big = model.maximized { TileView(tile: big, model: model, accent: accent, isMaximized: true, compact: false) }
            else if model.layout == .spotlight, model.tiles.count > 1 { spotlight }
            else { grid }
        }
        .frame(minWidth: 720, minHeight: 420)
        .navigationTitle(title)
        .toolbar { toolbar }
        .popover(isPresented: $showPicker, arrowEdge: .bottom) { ChannelPicker(model: model, replacing: nil) { showPicker = false } }
        .alert("Save this set of channels", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName); presetName = "" }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: { Text("Bring the same channels back later from the Sets menu.") }
        .onDisappear { model.removeAll() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.refreshGuide() }
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234"), phases: .down) { press in
            if let n = Int(press.characters) { model.selectTile(at: n - 1) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "mM"), phases: .down) { _ in model.toggleMute(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { _ in
            if let a = model.audible { model.toggleMaximize(a.id) }; return .handled
        }
        .onKeyPress(.escape) { if model.maximizedID != nil { model.restoreFromMaximize(); return .handled }; return .ignored }
    }

    private var title: String {
        model.tiles.isEmpty ? "Multi-View" : "Multi-View · \(model.tiles.count) channel\(model.tiles.count == 1 ? "" : "s")"
    }

    // MARK: layouts

    private var grid: some View {
        let showAdd = !model.isFull && model.tiles.count > 1          // a lone channel fills the window
        let cols = model.tiles.count <= 1 ? 1 : 2
        let cells: [GridCell] = model.tiles.map { .tile($0) } + (showAdd ? [.add] : [])
        let rows = stride(from: 0, to: cells.count, by: cols).map { Array(cells[$0..<min($0 + cols, cells.count)]) }
        // plain stacks, not a lazy grid: every tile's video view is created up front and never re-created while scrolling or resizing
        return VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(row) { cell in
                        switch cell {
                        case .tile(let t): TileView(tile: t, model: model, accent: accent, isMaximized: false, compact: false)
                        case .add: AddSlot { showPicker = true }
                        }
                    }
                    if row.count < cols { Color.black.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }
    }

    private enum GridCell: Identifiable {
        case tile(MultiViewModel.Tile), add
        var id: String { switch self { case .tile(let t): t.id.uuidString; case .add: "add" } }
    }

    private var spotlight: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                if let big = model.spotlight { TileView(tile: big, model: model, accent: accent, isMaximized: false, compact: false) }
                let others = model.others
                let slots = others.count + (model.isFull ? 0 : 1)
                VStack(spacing: 2) {
                    ForEach(others) { t in TileView(tile: t, model: model, accent: accent, isMaximized: false, compact: true).frame(height: (g.size.height - CGFloat(slots - 1) * 2) / CGFloat(slots)) }
                    if !model.isFull { AddSlot { showPicker = true } }
                }
                .frame(width: max(220, g.size.width * 0.26))
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { showPicker = true } label: { Label("Add Channel", systemImage: "plus") }
                .disabled(model.isFull).help(model.isFull ? "Multi-View holds four channels" : "Add a channel")
        }
        ToolbarItem {
            Picker("Layout", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                ForEach(MultiViewModel.Layout.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).help("Grid shows every channel equally. Spotlight makes one large.").disabled(model.tiles.count < 2)
        }
        ToolbarItem {
            Button { model.toggleMute() } label: { Label(model.isMuted ? "Unmute" : "Mute All", systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2") }
                .disabled(model.tiles.isEmpty).help("Mute or restore the sound (M)")
        }
        ToolbarItem {
            Menu {
                Button("Save Current Channels…") { showSave = true }.disabled(model.tiles.isEmpty)
                if !model.presets.isEmpty {
                    Divider()
                    ForEach(model.presets) { p in Button("\(p.name) · \(p.channelIDs.count)") { model.load(p) } }
                    Divider()
                    Menu("Delete a Set") { ForEach(model.presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p.id) } } }
                }
            } label: { Label("Sets", systemImage: "square.stack") }
            .help("Save the channels on screen as a set, or bring one back")
        }
        ToolbarItem { Button { model.removeAll() } label: { Label("Close All", systemImage: "xmark.rectangle") }.disabled(model.tiles.isEmpty).help("Stop and remove every channel") }
    }
}

// MARK: - empty state and add slot

private struct EmptyMultiView: View {
    let add: () -> Void
    let presets: [MultiViewModel.Preset]
    let load: (MultiViewModel.Preset) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.55))
            VStack(spacing: 4) {
                Text("Watch up to four channels at once").font(.title3.weight(.semibold))
                Text("One has the sound; click another to switch it. Keys: 1–4 pick a tile, M mutes, F fills the window.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button(action: add) { Label("Add a Channel", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            if !presets.isEmpty {
                VStack(spacing: 6) {
                    Text("Your sets").font(.caption).foregroundStyle(.white.opacity(0.5))
                    HStack { ForEach(presets.prefix(4)) { p in Button(p.name) { load(p) }.buttonStyle(.bordered) } }
                }.padding(.top, 6)
            }
        }
        .foregroundStyle(.white).padding()
    }
}

private struct AddSlot: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.system(size: 26, weight: .light))
                Text("Add channel").font(.callout)
            }
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(hovering ? 0.07 : 0.03))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel("Add a channel")
    }
}

// MARK: - tile

private struct TileView: View {
    let tile: MultiViewModel.Tile
    let model: MultiViewModel
    let accent: Color
    let isMaximized: Bool
    let compact: Bool
    @State private var hovering = false
    @State private var showSwap = false

    var body: some View {
        ZStack {
            TileVideo(player: tile.engine.player)
            status
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }
            .opacity(hovering || showSwap || !tile.isAudible ? 1 : 0.0001)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .overlay(Rectangle().strokeBorder(tile.isAudible ? accent : .clear, lineWidth: 2).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleMaximize(tile.id) }
        .onTapGesture { model.setAudible(tile.id) }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.channel.name + (tile.isAudible ? ", sound on" : ""))
    }

    @ViewBuilder private var status: some View {
        if let failure = tile.failure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text(failure).font(.callout).multilineTextAlignment(.center)
                if let d = tile.failureDetail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).lineLimit(3).textSelection(.enabled) }
                HStack { Button("Try Again") { model.retry(tile.id) }; Button("Change Channel") { showSwap = true } }
            }
            .foregroundStyle(.white.opacity(0.9)).padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.55))
        } else if tile.isWorking {
            VStack(spacing: 8) {
                ChannelLogo(url: tile.channel.logoURL, name: tile.channel.name, size: compact ? 36 : 56)
                ProgressView().controlSize(.small)
                if tile.reconnecting { Text("Reconnecting…").font(.caption).foregroundStyle(.white.opacity(0.7)) }
            }
        } else if tile.state == .buffering || tile.state == .recovering {
            ProgressView().controlSize(.small).padding(10).background(.black.opacity(0.5), in: Circle())
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !compact { ChannelLogo(url: tile.channel.logoURL, name: tile.channel.name, size: 24) }
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.channel.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let p = tile.programme, !compact { Text(p.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if tile.isAudible { Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(accent).help("This tile has the sound").accessibilityHidden(true) }
        }
        .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let p = tile.programme, !compact, p.end > p.start {
                ProgressView(value: min(1, max(0, Date().timeIntervalSince(p.start) / p.end.timeIntervalSince(p.start)))).progressViewStyle(.linear).tint(accent)
            }
            HStack(spacing: 14) {
                button(tile.isAudible && !model.isMuted ? "speaker.wave.2.fill" : "speaker.slash", help: "Play this channel's sound") { model.setAudible(tile.id) }
                if model.tiles.count > 1 && !isMaximized { button("rectangle.leadinghalf.inset.filled", help: "Make this the large tile") { model.makeSpotlight(tile.id) } }
                button(isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: isMaximized ? "Back to all channels (Esc)" : "Fill the window (F)") { model.toggleMaximize(tile.id) }
                Spacer(minLength: 0)
                button("arrow.left.arrow.right", help: "Change channel") { showSwap = true }
                    .popover(isPresented: $showSwap, arrowEdge: .top) { ChannelPicker(model: model, replacing: tile.id) { showSwap = false } }
                button("arrow.clockwise", help: "Reload this channel") { model.retry(tile.id) }
                button("xmark", help: "Remove from Multi-View") { model.remove(tile.id) }
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var menu: some View {
        Button("Play Sound from This Channel") { model.setAudible(tile.id) }
        Button(isMaximized ? "Back to All Channels" : "Fill the Window") { model.toggleMaximize(tile.id) }
        if model.tiles.count > 1 { Button("Make Large Tile") { model.makeSpotlight(tile.id) } }
        Button("Change Channel…") { showSwap = true }
        Button("Reload") { model.retry(tile.id) }
        Divider()
        Button("Remove", role: .destructive) { model.remove(tile.id) }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

// MARK: - channel picker

/// Search your channels and add one (or swap one into a tile) without leaving the window.
private struct ChannelPicker: View {
    let model: MultiViewModel
    let replacing: UUID?
    let done: () -> Void
    @State private var text = ""
    @State private var favouritesOnly = false
    @State private var results: [Channel] = []
    @State private var guide: [String: EPGProgram] = [:]
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(replacing == nil ? "Find a channel to add" : "Find a channel to switch to", text: $text).textFieldStyle(.plain).focused($searching)
                        .onSubmit { if let first = results.first(where: { !isShown($0) }) { choose(first) } }
                    if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Picker("Show", selection: $favouritesOnly) { Text("All channels").tag(false); Text("Favourites").tag(true) }.pickerStyle(.segmented).labelsHidden()
            }.padding(12)
            Divider()
            if results.isEmpty {
                Text(text.isEmpty && favouritesOnly ? "No favourites yet. Star channels in Live TV." : "No channels found.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { c in
                    Button { choose(c) } label: {
                        HStack(spacing: 10) {
                            ChannelLogo(url: c.logoURL, name: c.name, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).lineLimit(1)
                                Text(guide[c.id]?.title ?? c.categoryName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if isShown(c) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(isShown(c))
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 360, height: 460)
        .onAppear { searching = true }
        .task(id: "\(text)|\(favouritesOnly)") {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            results = model.find(text, favouritesOnly)
        }
        .task(id: results.map(\.id)) {
            guide = model.programmes(for: Array(results.prefix(40).map(\.id)))
        }
    }

    private func isShown(_ c: Channel) -> Bool { model.tiles.contains { $0.channel.id == c.id } }

    private func choose(_ c: Channel) {
        if let replacing { model.replace(replacing, with: c) } else { model.add(c) }
        done()
    }
}
