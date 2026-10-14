import SwiftUI

/// How the library is organised, refreshed and shown.
struct LibrarySettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Refreshing") {
                Picker("Playlists", selection: $s.catalogRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Refresh when the app opens", isOn: $s.refreshOnOpen)
                Picker("Programme guide", selection: $s.guideRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Keep past programmes", selection: $s.guideRetentionDays) { Text("3 hours").tag(0); Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7) }
            }.listRowBackground(ColorTokens.surface)
            Section("Showing") {
                Toggle("Group quality variants (HD, FHD…) into one channel", isOn: $s.collapseDuplicates)
                Toggle("Hide folders with nothing in them", isOn: $s.hideEmptyFolders)
                Picker("Channel order", selection: $s.defaultChannelSort) { ForEach(ChannelSortPreference.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Movie and series order", selection: $s.defaultLibrarySort) { ForEach(LibrarySortPreference.allCases) { Text($0.rawValue).tag($0) } }
            }.listRowBackground(ColorTokens.surface)
            Section {
                Toggle("Programme reminders", isOn: $s.remindersEnabled)
                Toggle("Resume the last channel when the app opens", isOn: $s.resumeLastChannel)
            }.listRowBackground(ColorTokens.surface)
            Section("Organise") {
                NavigationLink("Folders") { FoldersView() }
                NavigationLink("Backup and Restore") { BackupView() }
                NavigationLink("Storage and Maintenance") { StorageView() }
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Library and Guide").themed("Library and Guide")
    }
}

/// Reorder and hide the folders of each section.
struct FoldersView: View {
    @Environment(AppState.self) private var state
    @State private var section = AppTab.liveTV
    @State private var order: [SidebarEntry] = []

    var body: some View {
        List {
            Section { Picker("Section", selection: $section) { Text("Live TV").tag(AppTab.liveTV); Text("Movies").tag(AppTab.movies); Text("Series").tag(AppTab.series) }.pickerStyle(.segmented) }.listRowBackground(ColorTokens.surface)
            Section {
                ForEach(order) { e in
                    HStack { Text(e.title); Spacer(); if let n = e.count { Text("\(n)").foregroundStyle(.secondary).font(.caption) } }
                        .swipeActions { Button(role: .destructive) { state.hideFolder(e.id) } label: { Label("Hide", systemImage: "eye.slash") } }
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to); state.reorderFolders(tab: section, entryIDs: order.map(\.id)) }
            } footer: { Text("Drag to reorder. Swipe to hide a folder; hidden folders can be brought back by restoring a backup made before hiding.") }.listRowBackground(ColorTokens.surface)
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Folders").themed("Folders")
        .onAppear { order = state.folderEntries(for: section) }
        .onChange(of: section) { _, s in order = state.folderEntries(for: s) }
        .onChange(of: state.catalogVersion) { _, _ in order = state.folderEntries(for: section) }
    }
}
