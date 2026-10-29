import SwiftUI
import AVFoundation

private struct TileVideo: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView(); v.backgroundColor = .black
        v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}

/// Up to four live channels at once, one with sound. Best on iPad; works on iPhone in landscape.
struct MultiViewScreen: View {
    let model: MultiViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var swapTile: UUID?
    @State private var showSave = false
    @State private var presetName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if model.tiles.isEmpty { empty }
                else if let big = model.maximized { tile(big, compact: false) }
                else { layout }
            }
            .navigationTitle("Multi-View").navigationBarTitleDisplayMode(.inline).clearTopBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.toggleMute() } label: { Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2") }.disabled(model.tiles.isEmpty).accessibilityLabel("Mute all")
                    Menu {
                        Picker("Layout", selection: Binding(get: { model.layout }, set: { model.layout = $0 })) {
                            ForEach(MultiViewModel.Layout.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                        }
                        Divider()
                        Button("Save These Channels…") { showSave = true }.disabled(model.tiles.isEmpty)
                        ForEach(model.presets) { p in Button("\(p.name) · \(p.channelIDs.count)") { model.load(p) } }
                        if !model.presets.isEmpty { Menu("Delete a Set") { ForEach(model.presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p.id) } } } }
                        Divider()
                        Button("Close All", role: .destructive) { model.removeAll() }.disabled(model.tiles.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { showPicker = true } label: { Image(systemName: "plus") }.disabled(model.isFull).accessibilityLabel("Add channel")
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showPicker) { MVPicker(model: model, replacing: nil) }
            .sheet(item: Binding(get: { swapTile.map(IDBox.init) }, set: { swapTile = $0?.id })) { MVPicker(model: model, replacing: $0.id) }
            .alert("Save this set of channels", isPresented: $showSave) {
                TextField("Name", text: $presetName)
                Button("Save") { model.savePreset(named: presetName); presetName = "" }
                Button("Cancel", role: .cancel) { presetName = "" }
            }
        }
        .preferredColorScheme(.dark)
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { model.refreshGuide() } } }
        .alert("Your provider's limit", isPresented: Binding(get: { model.pendingAdd != nil }, set: { if !$0 { model.cancelPendingAdd() } })) {
            Button("Open Anyway") { model.confirmPendingAdd() }
            Button("Cancel", role: .cancel) { model.cancelPendingAdd() }
        } message: { Text(model.pendingAdd?.message ?? "") }
        .onDisappear { model.removeAll() }
    }

    private struct IDBox: Identifiable { let id: UUID }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x2").appFont(40, .light).foregroundStyle(.secondary)
            Text("Watch up to four channels at once").font(.title3.weight(.semibold))
            Text("One has the sound; tap another to switch it. Double-tap a tile to fill the screen.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { showPicker = true } label: { Label("Add a Channel", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            if !model.presets.isEmpty { HStack { ForEach(model.presets.prefix(3)) { p in Button(p.name) { model.load(p) }.buttonStyle(.bordered) } } }
        }.padding(24)
    }

    private var layout: some View {
        GeometryReader { g in
            let landscape = g.size.width > g.size.height
            if model.layout == .spotlight, model.tiles.count > 1, let big = model.spotlight {
                let strip = model.others
                let stack: AnyLayout = landscape ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
                let stripLayout: AnyLayout = landscape ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                stack {
                    tile(big, compact: false)
                    stripLayout { ForEach(strip) { tile($0, compact: true) } }
                        .frame(width: landscape ? g.size.width * 0.28 : nil, height: landscape ? nil : g.size.height * 0.26)
                }
            } else {
                let cols = model.tiles.count <= 1 ? 1 : (landscape || g.size.width > 700 ? 2 : 1)
                let rows = Int((Double(model.tiles.count) / Double(cols)).rounded(.up))
                let h = (g.size.height - CGFloat(rows - 1) * 2) / CGFloat(max(1, rows))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols), spacing: 2) {
                    ForEach(model.tiles) { tile($0, compact: false).frame(height: h) }
                }
            }
        }
    }

    private func tile(_ t: MultiViewModel.Tile, compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            TileVideo(player: t.engine.player)
            if let failure = t.failure {
                VStack(spacing: 8) {
                    Text(failure).font(.callout).multilineTextAlignment(.center)
                    if let d = t.failureDetail, !d.isEmpty { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    HStack { Button("Try Again") { model.retry(t.id) }; Button("Change") { swapTile = t.id } }.buttonStyle(.bordered)
                }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.6))
            } else if t.isWorking {
                VStack(spacing: 6) { ChannelLogo(url: t.channel.logoURL, name: t.channel.name, size: compact ? 30 : 48); ProgressView(); if t.reconnecting { Text("Reconnecting…").font(.caption2) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.channel.name).appFont(compact ? 11 : 13, .semibold).lineLimit(1)
                    if let p = t.programme, !compact { Text(p.title).appFont(11).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                }
                Spacer(minLength: 2)
                if t.isAudible && !model.isMuted { Image(systemName: "speaker.wave.2.fill").appFont(12).foregroundStyle(ColorTokens.accentDefault) }
            }
            .foregroundStyle(.white).padding(8).frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
        }
        .overlay(Rectangle().strokeBorder(t.isAudible ? ColorTokens.accentDefault : .clear, lineWidth: 2).allowsHitTesting(false))
        .clipped().contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleMaximize(t.id) }
        .onTapGesture { model.setAudible(t.id) }
        .contextMenu {
            Button("Play Sound", systemImage: "speaker.wave.2") { model.setAudible(t.id) }
            Button(model.maximizedID == t.id ? "Back to All" : "Fill the Screen", systemImage: "arrow.up.left.and.arrow.down.right") { model.toggleMaximize(t.id) }
            if model.tiles.count > 1 { Button("Make Large Tile", systemImage: "rectangle.leadinghalf.inset.filled") { model.makeSpotlight(t.id) } }
            Button("Change Channel…", systemImage: "arrow.left.arrow.right") { swapTile = t.id }
            Button("Reload", systemImage: "arrow.clockwise") { model.retry(t.id) }
            Button("Remove", systemImage: "xmark", role: .destructive) { model.remove(t.id) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(t.channel.name + (t.isAudible ? ", sound on" : ""))
    }
}

private struct MVPicker: View {
    let model: MultiViewModel
    let replacing: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var favouritesOnly = false
    @State private var results: [Channel] = []
    @State private var guide: [String: EPGProgram] = [:]

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $favouritesOnly) { Text("All channels").tag(false); Text("Favourites").tag(true) }.pickerStyle(.segmented).listRowBackground(Color.clear)
                ForEach(results) { c in
                    let shown = model.tiles.contains { $0.channel.id == c.id }
                    Button {
                        if let replacing { model.replace(replacing, with: c) } else { model.requestAdd(c) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ChannelLogo(url: c.logoURL, name: c.name, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).lineLimit(1)
                                Text(guide[c.id]?.title ?? c.categoryName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if shown { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.press).disabled(shown)
                }
            }
            .listStyle(.plain)
            .navigationTitle(replacing == nil ? "Add Channel" : "Change Channel").navigationBarTitleDisplayMode(.inline).clearTopBar()
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a channel")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
        .task(id: "\(text)|\(favouritesOnly)") {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            results = model.find(text, favouritesOnly)
            guide = model.programmes(for: Array(results.prefix(40).map(\.id)))
        }
    }
}
