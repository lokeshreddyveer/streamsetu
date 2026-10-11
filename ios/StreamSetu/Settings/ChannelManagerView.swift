import SwiftUI

/// Every channel of the active playlist in one place: rename, hide, and choose which guide entry it uses.
struct ChannelManagerView: View {
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var channels: [Channel] = []
    @State private var hidden: Set<String> = []
    @State private var overridden: Set<String> = []
    @State private var mapped: Set<String> = []
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var editing: Channel?

    enum Filter: String, CaseIterable, Identifiable { case all = "All", hidden = "Hidden", renamed = "Changed", noGuide = "No guide"; var id: Self { self } }

    private var shown: [Channel] {
        channels.filter { c in
            switch filter {
            case .all: true
            case .hidden: hidden.contains(c.id)
            case .renamed: overridden.contains(c.id)
            case .noGuide: !mapped.contains(c.id)
            }
        }.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section { Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).listRowBackground(Color.clear) }.listRowBackground(ColorTokens.surface)
            ForEach(shown.prefix(400)) { c in
                Button { editing = c } label: {
                    HStack(spacing: 12) {
                        ChannelLogo(url: c.logoURL, name: c.name, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).lineLimit(1).foregroundStyle(hidden.contains(c.id) ? .secondary : .primary)
                            Text([c.categoryName, mapped.contains(c.id) ? "Guide ✓" : "No guide", hidden.contains(c.id) ? "Hidden" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if overridden.contains(c.id) { Image(systemName: "pencil.circle").foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.press)
                .swipeActions {
                    if hidden.contains(c.id) { Button { setHidden(c, false) } label: { Label("Show", systemImage: "eye") }.tint(.green) }
                    else { Button(role: .destructive) { setHidden(c, true) } label: { Label("Hide", systemImage: "eye.slash") } }
                }
            }
            if shown.count > 400 { Text("Showing 400 of \(shown.count). Search to narrow it down.").font(.caption).foregroundStyle(.secondary) }
        }
        .listStyle(.plain)
        .navigationTitle("Channel Manager").themed("Channel Manager")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search channels")
        .sheet(item: $editing) { c in ChannelEditSheet(channel: c) { Task { await load() } } }
        .task(id: state.catalogVersion) { await load() }
    }

    private func setHidden(_ c: Channel, _ on: Bool) {
        if on { try? container?.favoritesRepo.hide(c.id, kind: "channel"); hidden.insert(c.id) } else { try? container?.favoritesRepo.unhide(c.id); hidden.remove(c.id) }
        state.catalogVersion += 1
    }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        let r = await Task.detached { () -> ([Channel], Set<String>, Set<String>, Set<String>) in
            let list = (try? c.catalog.allChannelsForManagement(sourceID: sid)) ?? []
            return (list, Set((try? c.favoritesRepo.hiddenIDs(kind: "channel")) ?? []), (try? c.favoritesRepo.overrideIDs()) ?? [], (try? c.epgRepo.mappedChannelIDs()) ?? [])
        }.value
        channels = r.0; hidden = r.1; overridden = r.2; mapped = r.3
    }
}

private struct ChannelEditSheet: View {
    let channel: Channel
    var changed: () -> Void
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var epgID = ""
    @State private var guide: [(id: String, name: String)] = []
    @State private var search = ""

    private var matches: [(id: String, name: String)] {
        let t = search.trimmingCharacters(in: .whitespaces)
        return Array((t.isEmpty ? guide : guide.filter { $0.name.localizedCaseInsensitiveContains(t) || $0.id.localizedCaseInsensitiveContains(t) }).prefix(40))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField(channel.name, text: $name) }.listRowBackground(ColorTokens.surface)
                Section {
                    LabeledContent("Guide entry", value: epgID.isEmpty ? "Automatic" : epgID)
                    TextField("Search the guide", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(matches, id: \.id) { g in
                        Button { epgID = g.id } label: { HStack { VStack(alignment: .leading) { Text(g.name); Text(g.id).font(.caption).foregroundStyle(.secondary) }; Spacer(); if epgID == g.id { Image(systemName: "checkmark") } } }.buttonStyle(.press)
                    }
                    if !epgID.isEmpty { Button("Use Automatic Matching") { epgID = "" } }
                } header: { Text("Programme guide") } footer: { Text("Pick the guide entry that belongs to this channel when automatic matching got it wrong. Applies after the next guide refresh.") }.listRowBackground(ColorTokens.surface)
                Section { Button("Reset Changes", role: .destructive) { try? container?.favoritesRepo.clearOverride(itemID: channel.id); changed(); state.catalogVersion += 1; dismiss() } }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle(channel.name).themed(channel.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .task {
            guard let c = container else { return }
            let existing = try? c.favoritesRepo.override(for: channel.id)
            name = existing?.displayName ?? ""; epgID = existing?.epgID ?? ""
            let sid = channel.sourceID
            guide = await Task.detached { (try? c.epgRepo.guideChannels(sourceID: sid)) ?? [] }.value
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        try? container?.favoritesRepo.setOverride(itemID: channel.id, displayName: n.isEmpty || n == channel.name ? nil : n, categoryName: nil, epgID: epgID.isEmpty ? nil : epgID)
        changed(); state.catalogVersion += 1; dismiss()
    }
}
