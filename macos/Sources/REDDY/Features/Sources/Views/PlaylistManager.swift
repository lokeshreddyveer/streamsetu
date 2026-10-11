import SwiftUI
import AppKit

/// What a playlist's diagnostics export contains: only the host, never the path, query or login.
enum PlaylistReport {
    static func host(of address: String) -> String { URL(string: address)?.host ?? "local file" }

    static func text(source: PlaylistSource, counts: CatalogCounts, scopes: [SyncScopeState], hasLogin: Bool) -> String {
        var lines = ["Playlist: \(source.name)", "Type: \(source.type.title)", "Host: \(host(of: source.baseURL))",
                     "Enabled: \(source.enabled ? "yes" : "no")", "Login saved: \(hasLogin ? "yes" : "no")",
                     "Last sync: \(source.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")", "Status: \(source.syncStatus)",
                     "Channels: \(counts.channels)", "Movies: \(counts.movies)", "Series: \(counts.series)"]
        for s in scopes.sorted(by: { $0.scope < $1.scope }) {
            lines.append("\(s.scope): \(s.itemCount) items" + (s.lastSuccess.map { ", updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") + (s.error.map { ", error: \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// Two panes: the playlists on the left, and on the right everything about the selected one, in sections.
struct PlaylistManager: View {
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var selectedID: UUID?
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable { case overview = "Overview", connection = "Connection", catalog = "Catalog", health = "Health", guide = "Guide", sync = "Sync", diagnostics = "Diagnostics"; var id: String { rawValue } }

    private var selected: PlaylistSource? { state.sources.first { $0.id == selectedID } ?? state.sources.first }

    var body: some View {
        ReddyDialog(title: "Playlists", width: 920, onClose: { router.modal = nil }) {
            if state.sources.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlists", message: "Add an Xtream login or an M3U playlist to get started.", actionTitle: "Add playlist") { router.modal = .addPlaylist }.frame(height: 260)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 250)
                    Rectangle().fill(ColorTokens.line).frame(width: 1)
                    if let s = selected {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Section", selection: $section) { ForEach(Section.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                            ScrollView { PlaylistSectionView(source: s, section: section).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8) }.scrollIndicators(.hidden)
                        }
                        .padding(.leading, 20).id(s.id)
                    }
                }
                .frame(height: 520)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.sources) { s in
                        let on = s.id == selected?.id
                        Button { selectedID = s.id } label: {
                            HStack(spacing: 10) {
                                Circle().fill(dot(s)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(Typography.rowMedium).lineLimit(1)
                                    Text(s.enabled ? s.type.title : "\(s.type.title) · off").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? ColorTokens.lineStrong : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
            HStack {
                SecondaryButton(title: "Refresh all", symbol: "arrow.clockwise") { state.syncAll() }
                Spacer()
            }
            PrimaryButton(title: "Add playlist", symbol: "plus") { router.modal = .addPlaylist }
        }.padding(.trailing, 16)
    }

    private func dot(_ s: PlaylistSource) -> Color {
        if let p = state.syncProgress[s.id]?.state { if case .failed = p { return ColorTokens.danger }; if p.isBusy { return ColorTokens.warning } }
        if !s.enabled { return ColorTokens.textTertiary }
        return s.syncStatus == "failed" ? ColorTokens.danger : s.syncStatus == "completed" ? ColorTokens.success : ColorTokens.textTertiary
    }
}

private struct PlaylistSectionView: View {
    let source: PlaylistSource
    let section: PlaylistManager.Section
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @State private var counts = CatalogCounts()
    @State private var scopes: [SyncScopeState] = []
    @State private var coverage: (channels: Int, programs: Int, mapped: Int, lastUpdate: Date?)?
    @State private var confirmDelete = false
    @State private var showEdit = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var copied = false
    @State private var engineChoice: PlaybackEnginePreference?
    @State private var catchupOffset = 0
    @State private var showHeaders = false
    @State private var userAgentText = ""
    @State private var headerText = ""
    @State private var headerProblems: [String] = []
    @State private var headerMessage: String?
    @State private var guideShiftMinutes = 0
    @State private var bufferingChoice: BufferingMode?

    private var progress: SyncProgress? { state.syncProgress[source.id] }
    private var busy: Bool { progress?.state.isBusy == true }
    private var hasLogin: Bool { container?.sources.hasCredentials(source) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !hasLogin { needsLogin }
            switch section {
            case .overview: overview
            case .connection: connection
            case .catalog: catalog
            case .health: PlaylistHealthView(source: source)
            case .guide: guide
            case .sync: sync
            case .diagnostics: diagnostics
            }
        }
        .task(id: "\(source.id)-\(state.catalogVersion)-\(busy)") { await load() }
        .sheet(isPresented: $showEdit) { EditSourceSheet(source: source) }
        .confirmationDialog("Remove \(source.name)?", isPresented: $confirmDelete) {
            Button("Remove Playlist and Its Data", role: .destructive) { try? container?.sources.remove(source.id); state.reload(); state.catalogVersion += 1 }
        } message: { Text("Its channels, movies, series, favorites and history are removed from this Mac. The provider's account is not affected.") }
    }

    // MARK: sections

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(Typography.title)
                    HStack(spacing: 6) { Circle().fill(statusColor).frame(width: 7, height: 7); Text(statusText) }.font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: { on in try? container?.sources.setEnabled(source.id, on); state.reload(); state.catalogVersion += 1 }))
                    .toggleStyle(.switch)
            }
            HStack(spacing: 28) { stat("Live channels", counts.channels); stat("Movies", counts.movies); stat("Series", counts.series) }
            if let p = progress, p.state.isBusy { Text(p.state.label).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            HStack {
                SecondaryButton(title: "Refresh", symbol: "arrow.clockwise") { state.sync(source.id) }.disabled(busy || !hasLogin)
                SecondaryButton(title: "Refresh Guide", symbol: "calendar") { state.sync(source.id, forceGuide: true) }.disabled(busy || !hasLogin)
                if busy { SecondaryButton(title: "Cancel", symbol: "xmark") { state.cancelSync(source.id) } }
                Spacer()
                SecondaryButton(title: "Edit", symbol: "pencil") { showEdit = true }
                SecondaryButton(title: "Remove", symbol: "trash") { confirmDelete = true }
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            fact("Type", source.type.title)
            fact("Host", PlaylistReport.host(of: source.baseURL))
            fact("Login", source.type == .m3uLocal ? "Not needed (local file)" : hasLogin ? "Saved in your Keychain" : "Missing")
            if let c = source.capabilities as SourceCapabilities?, c.live || c.movies || c.series {
                fact("Provides", [c.live ? "Live TV" : nil, c.movies ? "Movies" : nil, c.series ? "Series" : nil, c.epg ? "Guide" : nil].compactMap { $0 }.joined(separator: ", "))
            }
            playbackOverrides
            requestHeaders
            HStack {
                SecondaryButton(title: testing ? "Testing…" : "Test connection", symbol: "bolt.horizontal") { Task { await test() } }.disabled(testing || !hasLogin || source.type == .m3uLocal)
                SecondaryButton(title: hasLogin ? "Change login" : "Add login", symbol: "key") { showEdit = true }
            }
            if let r = testResult { Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(Typography.caption).foregroundStyle(r.ok ? ColorTokens.success : ColorTokens.warning) }
        }
    }

    /// This playlist's own player engine and buffering. IPTV providers differ, so one can need a choice the others don't.
    @ViewBuilder private var playbackOverrides: some View {
        if let settings = container?.settings {
            VStack(alignment: .leading, spacing: 10) {
                Text("Playback for this playlist").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                overrideRow("Player engine", help: "Use MPV if this provider's streams stutter or fail in AVPlayer.") {
                    Picker("Player engine", selection: Binding(get: { engineChoice }, set: { engineChoice = $0; settings.setEngineOverride($0, for: source.id) })) {
                        Text("Use app setting").tag(PlaybackEnginePreference?.none)
                        ForEach(PlaybackEnginePreference.allCases) { Text($0.rawValue).tag(PlaybackEnginePreference?.some($0)) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                overrideRow("Buffering", help: "Applies to the next stream you start.") {
                    Picker("Buffering", selection: Binding(get: { bufferingChoice }, set: { bufferingChoice = $0; settings.setBufferingOverride($0, for: source.id) })) {
                        Text("Use app setting").tag(BufferingMode?.none)
                        ForEach(BufferingMode.allCases) { Text($0.title).tag(BufferingMode?.some($0)) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .task(id: source.id) { engineChoice = settings.engineOverride(for: source.id); bufferingChoice = settings.bufferingOverride(for: source.id) }
        }
    }

    /// For providers that only answer certain players or need a Referer. Sent on every request this playlist makes.
    @ViewBuilder private var requestHeaders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(AnimationTokens.standard) { showHeaders.toggle() } } label: {
                HStack {
                    Text("Advanced connection").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary).rotationEffect(.degrees(showHeaders ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showHeaders {
                Text("If this provider refuses to play or load, try presenting as another player. These apply to this playlist only: its catalog, guide and streams.")
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("User-Agent (leave empty for the default)", text: $userAgentText).textFieldStyle(.roundedBorder)
                    Menu("Presets") { ForEach(SourceHeaders.presets, id: \.name) { p in Button(p.name) { userAgentText = p.value } } }.menuStyle(.button).fixedSize()
                }
                Text("Other headers, one per line").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                TextEditor(text: $headerText).font(Typography.mono).frame(height: 70).scrollContentBackground(.hidden)
                    .padding(6).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .topLeading) { if headerText.isEmpty { Text("Referer: https://example.com/").font(Typography.mono).foregroundStyle(ColorTokens.textTertiary).padding(11).allowsHitTesting(false) } }
                Text("Passwords and cookies can't be added here.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                ForEach(headerProblems, id: \.self) { Text($0).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                HStack {
                    SecondaryButton(title: "Save") { saveHeaders() }
                    SecondaryButton(title: "Use defaults") { userAgentText = ""; headerText = ""; headerProblems = []; saveHeaders() }
                    if let m = headerMessage { Text(m).font(Typography.caption).foregroundStyle(ColorTokens.success) }
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: source.id) {
            let h = container?.sources.headers(for: source.id) ?? SourceHeaders()
            userAgentText = h.userAgent ?? ""; headerText = h.text; headerProblems = []; headerMessage = nil
        }
    }

    private func saveHeaders() {
        guard let c = container else { return }
        headerProblems = SourceHeaders.parse(headerText).problems
        c.sources.setHeaders(userAgent: userAgentText, extraText: headerText, for: source.id)
        headerMessage = headerProblems.isEmpty ? "Saved. The next connection uses it." : "Saved, except the lines above."
    }

    private func overrideRow<C: View>(_ title: String, help: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(Typography.row); Text(help).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            Spacer(minLength: 12)
            control()
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whether every folder the provider lists reached the sidebar, per content type.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            CategoryCheck(source: source)
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            fact("Guide address", source.epgURL.map { PlaylistReport.host(of: $0) } ?? (source.capabilities.epg ? "Provided by the playlist" : "None"))
            if let c = coverage, c.programs > 0 {
                HStack(spacing: 28) { stat("Programmes", c.programs); stat("Matched channels", c.mapped); stat("Guide channels", c.channels) }
                if let d = c.lastUpdate { fact("Last updated", d.formatted(.relative(presentation: .named))) }
            } else { Text("No guide data yet.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            SecondaryButton(title: "Refresh Guide", symbol: "calendar") { state.sync(source.id, forceGuide: true) }.disabled(busy || !hasLogin)
            guideShift
            catchupClock
        }
    }

    /// Moves this playlist's guide earlier or later. Applied while the guide downloads, so it refreshes the guide at once.
    @ViewBuilder private var guideShift: some View {
        if let settings = container?.settings {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guide time shift").font(Typography.row)
                        Text("If this playlist's programmes are hours early or late, move them. Everything in the guide and Live TV follows.")
                            .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("Guide time shift", selection: Binding(get: { guideShiftMinutes }, set: { v in
                        guideShiftMinutes = v; settings.setGuideShiftMinutes(v, for: source.id); state.sync(source.id, forceGuide: true)
                    })) {
                        ForEach(Array(stride(from: -720, through: 720, by: 30)), id: \.self) { m in Text(Self.shiftLabel(m)).tag(m) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .task(id: source.id) { guideShiftMinutes = settings.guideShiftMinutes(for: source.id) }
        }
    }

    static func shiftLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "No shift" }
        let a = abs(minutes)
        return "\(minutes < 0 ? "−" : "+")\(a / 60)h" + (a % 60 == 0 ? "" : " \(a % 60)m") + (minutes < 0 ? " (earlier)" : " (later)")
    }

    /// Catch-up addresses name the start time on the provider's clock. If past programmes play from the wrong moment, change this.
    @ViewBuilder private var catchupClock: some View {
        if let settings = container?.settings, source.type == .xtream {
            VStack(alignment: .leading, spacing: 8) {
                Text("Catch-up").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Provider's clock").font(Typography.row)
                        Text("Channels that offer catch-up show earlier programmes in Live TV and the guide. If one starts at the wrong time, choose the time zone your provider uses.")
                            .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("Provider's clock", selection: Binding(get: { catchupOffset }, set: { catchupOffset = $0; settings.setCatchupOffsetMinutes($0, for: source.id) })) {
                        ForEach(Array(stride(from: -720, through: 840, by: 30)), id: \.self) { m in Text(Self.offsetLabel(m)).tag(m) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SecondaryButton(title: "Use this Mac's time zone") {
                    let m = TimeZone.current.secondsFromGMT() / 60
                    let snapped = (m / 30) * 30
                    catchupOffset = snapped; settings.setCatchupOffsetMinutes(snapped, for: source.id)
                }
            }
            .padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .task(id: source.id) { catchupOffset = settings.catchupOffsetMinutes(for: source.id) }
        }
    }

    static func offsetLabel(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "−" : "+"
        let a = abs(minutes)
        return minutes == 0 ? "UTC" : "UTC\(sign)\(a / 60):\(String(format: "%02d", a % 60))"
    }

    private var sync: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = progress, p.state.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.state.label).font(Typography.bodyMedium)
                    phase("Live channels", p.liveCount); phase("Movies", p.movieCount); phase("Series", p.seriesCount)
                    if let g = p.guide { Text("Guide: \(g)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    Text("Your existing library stays available while this runs.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            ForEach(scopes, id: \.scope) { s in
                HStack {
                    Text(s.scope.capitalized).font(Typography.captionMedium).frame(width: 80, alignment: .leading)
                    Text("\(s.itemCount.formatted()) items").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    Spacer()
                    if let e = s.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(Typography.caption).foregroundStyle(ColorTokens.warning).lineLimit(1) }
                    else if let d = s.lastSuccess { Text(d.formatted(.relative(presentation: .named))).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                }
            }
            if scopes.isEmpty && !busy { Text("Not synced yet.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A report you can share when asking for help. It names the host only; addresses, logins and tokens are never included.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(PlaylistReport.text(source: source, counts: counts, scopes: scopes, hasLogin: hasLogin)).font(Typography.mono).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            SecondaryButton(title: copied ? "Copied" : "Copy report", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(PlaylistReport.text(source: source, counts: counts, scopes: scopes, hasLogin: hasLogin), forType: .string)
                copied = true
            }
        }
    }

    // MARK: pieces

    private var needsLogin: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(ColorTokens.warning)
            Text("This playlist needs its login again (it was restored without it).").font(Typography.caption)
            Spacer()
            SecondaryButton(title: "Add login") { showEdit = true }
        }.padding(12).background(ColorTokens.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).frame(width: 110, alignment: .leading); Text(v).font(Typography.row).textSelection(.enabled); Spacer() }
    }
    private func stat(_ t: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(n.formatted()).font(Typography.title); Text(t).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
    }
    private func phase(_ t: String, _ n: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: n != nil ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(n != nil ? ColorTokens.success : ColorTokens.textTertiary)
            Text(t).font(Typography.caption); Spacer(); if let n { Text(n.formatted()).font(Typography.mono).foregroundStyle(ColorTokens.textSecondary) }
        }
    }

    private var statusText: String {
        if let st = progress?.state { return st.label }
        if let d = source.lastSync { return "Updated \(d.formatted(.relative(presentation: .named)))" }
        return "Not synced yet"
    }
    private var statusColor: Color {
        if let s = progress?.state { if case .failed = s { return ColorTokens.danger }; if s.isBusy { return ColorTokens.warning } }
        return source.syncStatus == "completed" ? ColorTokens.success : source.syncStatus == "failed" ? ColorTokens.danger : ColorTokens.textTertiary
    }

    private func test() async {
        guard let c = container else { return }
        testing = true; testResult = nil
        let started = Date()
        do {
            let provider = try c.sources.makeProvider(for: source)
            _ = try await provider.validate()
            testResult = (true, "Connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch { testResult = (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        testing = false
    }

    private func load() async {
        guard let c = container else { return }
        let id = source.id
        let (a, b, g) = await Task.detached { (try? c.catalog.counts(sourceID: id), try? c.catalog.syncStates(sourceID: id), try? c.epgRepo.guideCoverage(sourceID: id)) }.value
        counts = a ?? CatalogCounts(); scopes = (b ?? []).sorted { $0.scope < $1.scope }; coverage = g
    }
}
