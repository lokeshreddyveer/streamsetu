import SwiftUI

/// How the library is organised, refreshed and shown.
enum LibrarySettingsRoute: Hashable { case folders }

struct LibrarySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.container) private var container
    @State private var people: (done: Int, total: Int) = (0, 0)

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Refreshing") {
                Picker("Playlists", selection: $s.catalogRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.catalogRefresh")
                Toggle("Refresh when the app opens", isOn: $s.refreshOnOpen).atlas("setting.refreshOnOpen")
                Picker("Programme guide", selection: $s.guideRefresh) { ForEach(RefreshInterval.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.guideRefresh")
                Picker("Keep past programmes", selection: $s.guideRetentionDays) { Text("3 hours").tag(0); Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7) }.atlas("setting.guideRetentionDays")
            }.glossRow()
            Section("Showing") {
                Toggle("Group quality variants (HD, FHD…) into one channel", isOn: $s.collapseDuplicates).atlas("setting.collapseDuplicates")
                Toggle("Hide folders with nothing in them", isOn: $s.hideEmptyFolders).atlas("setting.hideEmptyFolders")
                Picker("Channel order", selection: $s.defaultChannelSort) { ForEach(ChannelSortPreference.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.defaultChannelSort")
                Picker("Movie and series order", selection: $s.defaultLibrarySort) { ForEach(LibrarySortPreference.allCases) { Text($0.rawValue).tag($0) } }.atlas("setting.defaultLibrarySort")
            }.glossRow()
            Section {
                Toggle("Programme reminders", isOn: $s.remindersEnabled).atlas("setting.remindersEnabled")
                Toggle("Resume the last channel when the app opens", isOn: $s.resumeLastChannel).atlas("setting.resumeLastChannel")
            }.glossRow()
            Section {
                LabeledContent("Movies read", value: "\(people.done.formatted()) of \(people.total.formatted())")
                Button("Read More Now") { container?.startPeopleIndex(fast: true) }.disabled(people.done >= people.total).atlas("setting.castReading")
            } header: { Text("Cast and directors") } footer: {
                Text("So you can search for an actor or a director. StreamSetu asks your playlists about one movie at a time, slowly and never while something is playing, and keeps what it learns.")
            }.glossRow()
            Section("Organise") {
                NavigationLink("Folders", value: LibrarySettingsRoute.folders).atlas("screen.ios.settings.folders")
            }.glossRow()
        }
        .task { while !Task.isCancelled { if let c = container { people = c.people.progress }; try? await Task.sleep(nanoseconds: 5_000_000_000) } }
        .navigationTitle("Library and Guide").atlasScreen("screen.ios.settings.library").themed("Library and Guide")
        .navigationDestination(for: LibrarySettingsRoute.self) { _ in FoldersView() }
    }
}

/// Reorder and hide the folders of each section.
struct FoldersView: View {
    @Environment(AppState.self) private var state
    @State private var section = AppTab.liveTV
    @State private var order: [SidebarEntry] = []

    var body: some View {
        List {
            Section { Picker("Section", selection: $section) { Text("Live TV").tag(AppTab.liveTV); Text("Movies").tag(AppTab.movies); Text("Series").tag(AppTab.series) }.pickerStyle(.segmented).atlas("control.ios.folders.section") }.glossRow()
            Section {
                ForEach(order) { e in
                    HStack { Text(e.title); Spacer(); if let n = e.count { Text("\(n)").foregroundStyle(.secondary).font(.caption) } }
                        .swipeActions { Button(role: .destructive) { state.hideFolder(e.id) } label: { Label("Hide", systemImage: "eye.slash") }.atlas("gesture.ios.swipeFolderHide") }
                        .atlas("gesture.ios.swipeFolderHide")
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to); state.reorderFolders(tab: section, entryIDs: order.map(\.id)) }
            } footer: { Text("Drag to reorder. Swipe to hide a folder; hidden folders can be brought back by restoring a backup made before hiding.") }.glossRow()
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Folders").atlasScreen("screen.ios.settings.folders").themed("Folders")
        .onAppear { order = state.folderEntries(for: section) }
        .onChange(of: section) { _, s in order = state.folderEntries(for: s) }
        .onChange(of: state.catalogVersion) { _, _ in order = state.folderEntries(for: section) }
    }
}
