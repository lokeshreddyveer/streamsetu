import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Looking after your own music files: a health report, renaming files into folders by a template, the list of changes with Undo, and the files you locked.
/// Music never changes a file while the collection is read-only (the default); everything here that writes says so and stays off until you allow it.
struct MusicLibraryHealthSheet: View {
    enum Tab: Hashable { case report, rename, history, locks }

    let hub: MusicHub
    let close: () -> Void
    @State private var tab: Tab = .report
    @State private var findings: [MusicHealthFinding] = []
    @State private var running = false
    @State private var ran = false
    @State private var deep = false
    @State private var progress: MusicLibraryHealth.Progress?
    @State private var task: Task<Void, Never>?
    @State private var readOnly = MusicCollectionSafety.isReadOnly()
    @State private var template = UserDefaults.standard.string(forKey: "music.collection.renameTemplate") ?? MusicRenameTemplate.defaultTemplate
    @State private var plan: (moves: [MusicRenameTemplate.Move], skipped: Int)?
    @State private var records = MusicChangeJournal.shared.all
    @State private var locks = Array(MusicCollectionSafety.locks()).sorted()
    @State private var note: String?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Library health")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.healthClose")
            }
            Picker("", selection: $tab) {
                Text(Localized.string("Report")).tag(Tab.report)
                Text(Localized.string("Rename files")).tag(Tab.rename)
                Text(Localized.string("Changes")).tag(Tab.history)
                Text(Localized.string("Locked")).tag(Tab.locks)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().atlas("control.music.healthTab")
            safetyRow
            if let note { Text(verbatim: note).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            switch tab {
            case .report: report
            case .rename: rename
            case .history: history
            case .locks: lockList
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 520)
        .onDisappear { task?.cancel() }
    }

    // MARK: safety

    private var safetyRow: some View {
        MusicSheetCard {
            Toggle(isOn: Binding(get: { readOnly }, set: { v in readOnly = v; UserDefaults.standard.set(v, forKey: MusicCollectionSafety.readOnlyKey) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localized.string("Read-only collection")).font(Typography.bodyMedium)
                    Text(Localized.string(readOnly ? "Music will not change any of your files. Turn this off to write tags or rename files; each change is backed up first and can be undone."
                                                   : "Writing is allowed. Every change is backed up first and listed under Changes, where it can be undone."))
                        .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }.toggleStyle(.switch).atlas("control.music.healthReadOnly")
        }
    }

    // MARK: report

    private var report: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(spacing: MusicSpace.sm) {
                Toggle(Localized.string("Also open every file (slower: finds damaged files and identical copies)"), isOn: $deep).toggleStyle(.switch).atlas("control.music.healthDeep")
                Spacer()
                if running { Button(Localized.string("Stop")) { task?.cancel() }.musicButton(.secondary, size: .compact).atlas("control.music.healthStop") }
                else { Button(Localized.string(ran ? "Check again" : "Check my library")) { start() }.musicButton(.primary, size: .compact).atlas("control.music.healthRun") }
                Button { exportInventory() } label: { Label(Localized.string("Export list"), systemImage: "square.and.arrow.up") }
                    .musicButton(.secondary, size: .compact).atlas("control.music.healthExport")
            }
            if running, let p = progress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))) { Text(verbatim: p.step).font(Typography.caption) }
            }
            if ran, !running, findings.isEmpty {
                Text(Localized.string("Nothing needs attention.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, MusicSpace.lg)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicSpace.sm) {
                    ForEach(MusicHealthFinding.Kind.allCases, id: \.self) { k in
                        let items = findings.filter { $0.kind == k }
                        if !items.isEmpty {
                            Text(verbatim: heading(k) + " (\(items.count))").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).padding(.top, MusicSpace.xs)
                            ForEach(items.prefix(60)) { f in findingRow(f) }
                            if items.count > 60 { Text(Localized.string("And %@ more.", String(items.count - 60))).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                        }
                    }
                }
            }
        }
    }

    private func heading(_ k: MusicHealthFinding.Kind) -> String {
        switch k {
        case .missingFile: Localized.string("Missing files")
        case .unreadable: Localized.string("Damaged or unreadable files")
        case .identicalCopies: Localized.string("Identical copies")
        case .incompleteAlbum: Localized.string("Albums with tracks missing")
        case .missingDisc: Localized.string("Albums with a disc missing")
        case .tagConflict: Localized.string("Tags that disagree")
        case .missingTags: Localized.string("Songs without details")
        case .orphanedArtwork: Localized.string("Unused cover pictures")
        case .changedFile: Localized.string("Files whose contents changed")
        }
    }

    private func findingRow(_ f: MusicHealthFinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: f.title).font(Typography.bodyMedium).lineLimit(2)
            if !f.detail.isEmpty { Text(verbatim: f.detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(3) }
            #if os(macOS)
            if let p = f.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                Button(Localized.string("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    .buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.healthReveal")
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(MusicSpace.sm)
        .background(RoundedRectangle(cornerRadius: MusicCorner.control).fill(ColorTokens.surface))
    }

    private func start() {
        running = true; ran = false; findings = []; progress = nil
        let deepNow = deep
        task = Task { @MainActor in
            let index = await LocalLibraryStore.shared.currentIndex()
            let art = LocalLibraryStore.shared.artworkDirectory
            let result = await Task.detached(priority: .utility) {
                await MusicLibraryHealth.run(entries: index.entries, artworkDirectory: art, deep: deepNow, manifest: .shared,
                                             progress: { p in Task { @MainActor in progress = p } }, isCancelled: { Task.isCancelled })
            }.value
            findings = result; running = false; ran = true
        }
    }

    private func exportInventory() {
        Task { @MainActor in
            let index = await LocalLibraryStore.shared.currentIndex()
            let text = MusicInventoryExport.csv(index.entries)
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Music inventory.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); note = Localized.string("Saved the list of %@ songs.", String(index.entries.count)) }
            catch { note = Localized.string("The list could not be saved.") }
            #endif
        }
    }

    // MARK: rename

    private var rename: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("Folders and file names follow this template. Parts you can use:")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(verbatim: MusicRenameTemplate.tokens.joined(separator: "  ")).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary)
            TextField(MusicRenameTemplate.defaultTemplate, text: $template).textFieldStyle(.roundedBorder).atlas("control.music.healthTemplate")
            HStack(spacing: MusicSpace.sm) {
                Button(Localized.string("Preview")) { preview() }.musicButton(.secondary, size: .compact).atlas("control.music.healthPreview")
                if let p = plan, !p.moves.isEmpty {
                    Button(Localized.plural(p.moves.count, one: "Rename %@ file", other: "Rename %@ files")) { applyRename(p.moves) }
                        .musicButton(.primary, size: .compact).disabled(readOnly).atlas("control.music.healthApplyRename")
                    if readOnly { Text(Localized.string("Turn off read-only first.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                }
            }
            if let p = plan {
                if p.moves.isEmpty { Text(Localized.string("Nothing would move.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                else {
                    Text(Localized.plural(p.moves.count, one: "%@ file would move.", other: "%@ files would move.") + (p.skipped > 0 ? " " + Localized.plural(p.skipped, one: "%@ was left out (locked or the name is taken).", other: "%@ were left out (locked or the name is taken).") : ""))
                        .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(p.moves.prefix(80)) { m in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: (m.from as NSString).lastPathComponent).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).lineLimit(1)
                                    Text(verbatim: "→ " + shortPath(m.to)).font(Typography.caption).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func shortPath(_ p: String) -> String { p.split(separator: "/").suffix(3).joined(separator: "/") }

    private func preview() {
        UserDefaults.standard.set(template, forKey: "music.collection.renameTemplate")
        let t = template.trimmingCharacters(in: .whitespaces).isEmpty ? MusicRenameTemplate.defaultTemplate : template
        Task { @MainActor in
            let index = await LocalLibraryStore.shared.currentIndex()
            let folders = await LocalLibraryStore.shared.folderPaths()
            let locked = MusicCollectionSafety.locks()
            // Each song moves inside the music folder it already lives in.
            var moves: [MusicRenameTemplate.Move] = [], skipped = 0
            for root in folders {
                let inRoot = index.entries.filter { $0.path.hasPrefix(root + "/") }
                let r = MusicRenameTemplate.plan(inRoot, root: root, template: t, locked: locked)
                moves += r.moves; skipped += r.skipped
            }
            plan = (moves, skipped)
        }
    }

    private func applyRename(_ moves: [MusicRenameTemplate.Move]) {
        guard MusicCollectionSafety.isReadOnly() == false else { return }
        Task { @MainActor in
            var done = 0
            let fm = FileManager.default
            for m in moves {
                guard MusicCollectionSafety.verdict(for: m.from) == .allowed, fm.fileExists(atPath: m.from), !fm.fileExists(atPath: m.to) else { continue }
                do {
                    try fm.createDirectory(atPath: (m.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fm.moveItem(atPath: m.from, toPath: m.to)
                    _ = MusicChangeJournal.shared.noteRename(from: m.from, to: m.to)
                    done += 1
                } catch { continue }
            }
            note = Localized.plural(done, one: "Renamed %@ file. Scanning your folders again…", other: "Renamed %@ files. Scanning your folders again…")
            plan = nil
            records = MusicChangeJournal.shared.all
            await LocalLibraryStore.shared.scan(thorough: true)
        }
    }

    // MARK: history

    private var history: some View {
        Group {
            if records.isEmpty { Text(Localized.string("No changes yet. Music has not changed any of your files.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, MusicSpace.lg) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MusicSpace.sm) {
                        ForEach(records.prefix(200)) { r in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: (r.path as NSString).lastPathComponent).font(Typography.bodyMedium).lineLimit(1)
                                    Text(verbatim: (r.kind == .rename ? Localized.string("Renamed") : Localized.string("Tags changed")) + " · " + r.summary + " · " + r.at.formatted(date: .abbreviated, time: .shortened))
                                        .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                if r.undone { Text(Localized.string("Undone")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                                else if r.kind == .rename || r.backupFile != nil {
                                    Button(Localized.string("Undo")) { undo(r) }.musicButton(.secondary, size: .compact).atlas("control.music.healthUndo")
                                }
                            }
                            .padding(MusicSpace.sm).background(RoundedRectangle(cornerRadius: MusicCorner.control).fill(ColorTokens.surface))
                        }
                    }
                }
            }
        }
    }

    private func undo(_ r: MusicChangeRecord) {
        let ok = MusicChangeJournal.shared.undo(r.id)
        note = ok ? Localized.string("Put the file back as it was.") : Localized.string("This change cannot be undone any more.")
        records = MusicChangeJournal.shared.all
        if ok { Task { await LocalLibraryStore.shared.scan(thorough: true) } }
    }

    // MARK: locks

    private var lockList: some View {
        Group {
            if locks.isEmpty {
                Text(Localized.string("No files are locked. Lock a song from its menu to keep Music from ever changing its file.")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(.vertical, MusicSpace.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MusicSpace.xs) {
                        ForEach(locks, id: \.self) { p in
                            HStack {
                                Image(systemName: "lock.fill").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textTertiary)
                                Text(verbatim: shortPath(p)).font(Typography.body).lineLimit(1)
                                Spacer(minLength: 0)
                                Button(Localized.string("Unlock")) { MusicCollectionSafety.setLocked([p], false); locks = Array(MusicCollectionSafety.locks()).sorted() }
                                    .musicButton(.secondary, size: .compact).atlas("control.music.healthUnlock")
                            }
                        }
                    }
                }
            }
        }
    }
}
