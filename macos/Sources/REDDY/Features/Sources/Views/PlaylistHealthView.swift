import SwiftUI
import AppKit

/// Finds dead and slow channels in one playlist. Opt-in: nothing is tested until "Check" is pressed.
struct PlaylistHealthView: View {
    let source: PlaylistSource
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state

    enum Scope: Hashable { case sample, folder(String) }
    @State private var scope: Scope = .sample
    @State private var folders: [CatalogCategory] = []
    @State private var running = false
    @State private var finished = 0
    @State private var total = 0
    @State private var results: [ChannelHealthResult] = []
    @State private var filter: Filter = .problems
    @State private var task: Task<Void, Never>?
    @State private var message: String?

    enum Filter: String, CaseIterable, Identifiable { case problems = "Problems", dead = "Dead", slow = "Slow or silent", all = "All"; var id: String { rawValue } }

    private var dead: [ChannelHealthResult] { results.filter { $0.health.isDead } }
    /// Slow to answer, or silent: worth knowing, but not proof of a dead channel.
    private var slow: [ChannelHealthResult] { results.filter { $0.health.isSlow || $0.health.isSilent } }
    private var shown: [ChannelHealthResult] {
        switch filter {
        case .problems: (dead + slow)
        case .dead: dead
        case .slow: slow
        case .all: results
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check which channels still answer, so you can hide the dead ones. It asks each channel for a few kilobytes and stops, two at a time. Some providers allow only one or two connections per login; if yours does, stop any playing channel first.")
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("What to check", selection: $scope) {
                    Text("A sample of 40 channels").tag(Scope.sample)
                    if !folders.isEmpty { Divider() }
                    ForEach(folders) { Text("Folder: \($0.name) (up to 200)").tag(Scope.folder($0.id)) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 300, alignment: .leading).disabled(running)
                if running { SecondaryButton(title: "Stop", symbol: "stop.fill") { task?.cancel() } }
                else { PrimaryButton(title: results.isEmpty ? "Check channels" : "Check again", symbol: "stethoscope") { start() } }
                Spacer(minLength: 0)
            }
            if running || total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(finished), total: Double(max(1, total)))
                    Text(running ? "Checked \(finished) of \(total)…" : "Checked \(finished) of \(total).").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            if !results.isEmpty {
                HStack(spacing: 16) {
                    stat("Working", results.count - dead.count - slow.count, ColorTokens.success)
                    stat("Slow or silent", slow.count, ColorTokens.warning)
                    stat("Dead", dead.count, ColorTokens.danger)
                }
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    SecondaryButton(title: "Hide dead channels", symbol: "eye.slash") { hideDead() }.disabled(dead.isEmpty || running)
                    SecondaryButton(title: "Copy report", symbol: "doc.on.doc") { copyReport() }
                    Spacer(minLength: 0)
                }
                if let message { Text(message).font(Typography.caption).foregroundStyle(ColorTokens.success) }
                if shown.isEmpty { Text(filter == .problems ? "No problems found in what was checked." : "Nothing here.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                LazyVStack(spacing: 0) {
                    ForEach(shown) { r in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(color(r.health)).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(Typography.row).lineLimit(1).truncationMode(.tail)
                                Text([r.category, r.health.label].compactMap { $0 }.joined(separator: " — ")).font(Typography.caption)
                                    .foregroundStyle(ColorTokens.textSecondary).lineLimit(2).truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                        Divider().overlay(ColorTokens.line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source.id) {
            guard let c = container else { return }
            let sid = source.id
            folders = await Task.detached { (try? c.catalog.categories(sourceID: sid, kind: .channel, includeHidden: true)) ?? [] }.value
        }
        .onDisappear { task?.cancel() }
    }

    private func color(_ h: ChannelHealth) -> Color {
        switch h { case .ok: ColorTokens.success; case .slow, .silent: ColorTokens.warning; case .dead: ColorTokens.danger }
    }

    private func stat(_ title: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text("\(n)").font(Typography.heading); Text(title).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
    }

    private func start() {
        guard let c = container else { return }
        running = true; results = []; finished = 0; total = 0; message = nil
        let sid = source.id, scope = scope
        task = Task {
            let channels = await Task.detached { () -> [Channel] in
                switch scope {
                case .sample: return Array(((try? c.catalog.channels(ChannelQuery(sourceID: sid, collapseVariants: false, limit: 2000))) ?? []).shuffled().prefix(40))
                case .folder(let id): return (try? c.catalog.channels(ChannelQuery(sourceID: sid, categoryID: id, collapseVariants: false, limit: 200))) ?? []
                }
            }.value
            total = channels.count
            let found = await c.channelHealth.check(channels) { done, _ in Task { @MainActor in finished = done } }
            results = found
            running = false
        }
    }

    private func hideDead() {
        guard let c = container else { return }
        let ids = dead.map(\.channelID)
        Task {
            await Task.detached { for id in ids { try? c.favoritesRepo.hide(id, kind: "channel") } }.value
            message = "Hid \(ids.count) dead channel\(ids.count == 1 ? "" : "s"). They stay in your library; show them again from the Channel manager."
            state.catalogVersion += 1
        }
    }

    private func copyReport() {
        let lines = ["Channel check for \(source.name)", "Working \(results.count - dead.count - slow.count) · Slow or silent \(slow.count) · Dead \(dead.count)", ""] +
            (dead + slow).map { "\($0.name)\($0.category.map { " [\($0)]" } ?? "") — \($0.health.label)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        message = "Report copied. It names channels only, never addresses or logins."
    }
}
