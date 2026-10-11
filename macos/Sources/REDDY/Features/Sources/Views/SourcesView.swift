import SwiftUI

struct EditSourceSheet: View {
    let source: PlaylistSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var guide = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var authKind: HTTPAuthKind = .none
    @State private var authUser = ""
    @State private var authSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Edit \(source.name)").font(Typography.title)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Guide (XMLTV) address — optional", text: $guide).textFieldStyle(.roundedBorder)
                #if os(macOS)
                SecondaryButton(title: "From File…", symbol: "doc") { chooseGuideFile() }
                #endif
            }
            if source.type.hasLogin {
                Text("Replace login").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                if source.type != .plex { TextField(source.type == .stalker ? "MAC address" : "Username", text: $username).textFieldStyle(.roundedBorder) }
                SecureField(source.type == .plex ? "Access token" : "Password", text: $password).textFieldStyle(.roundedBorder)
                Text("Leave blank to keep the saved login.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            if source.type == .m3uRemote {
                Text("Sign-in for this link").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                Picker("", selection: $authKind) { ForEach(HTTPAuthKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
                if authKind == .basic { TextField("Username", text: $authUser).textFieldStyle(.roundedBorder) }
                if authKind != .none { SecureField(authKind == .basic ? "Password" : "Token", text: $authSecret).textFieldStyle(.roundedBorder) }
                Text("Kept encrypted with the playlist's address, and sent with every request to it. Leave the password or token blank to keep the saved one.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            if let error { Text(error).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
            HStack { Spacer(); SecondaryButton(title: "Cancel") { dismiss() }; PrimaryButton(title: "Save", action: save) }
        }
        .padding(Spacing.section).frame(width: 460).background(ColorTokens.background)
        .onAppear {
            name = source.name; guide = source.epgURL ?? ""
            if source.type == .m3uRemote, let a = container?.sources.httpAuth(for: source.id) { authKind = a.kind; authUser = a.username }
        }
    }

    #if os(macOS)
    private func chooseGuideFile() {
        guard let u = WindowManager.chooseFile(types: ["xml", "gz"], prompt: "Use as Guide"), let c = container else { return }
        do { try c.sources.setGuideFile(source.id, fileURL: u); state.reload(); dismiss(); state.sync(source.id, forceGuide: true) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
    #endif

    private func save() {
        guard let c = container else { return }
        do {
            try c.sources.rename(source.id, to: name)
            try c.sources.setGuideURL(source.id, url: guide)
            if source.type.hasLogin, !password.isEmpty || (source.type == .stalker && !username.isEmpty) { try c.sources.updateXtreamLogin(source.id, username: username, password: password) }
            if source.type == .m3uRemote {
                let current = c.sources.httpAuth(for: source.id)
                if authKind == .none || !authSecret.isEmpty || authKind != current.kind { try c.sources.setHTTPAuth(source.id, kind: authKind, username: authUser, secret: authSecret) }
            }
            state.reload(); dismiss(); state.sync(source.id)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}


/// "Folders" check inside a playlist card: provider → parsed → stored → returned → displayed, per content type.
struct CategoryCheck: View {
    let source: PlaylistSource
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings
    @State private var open = false
    @State private var rows: [CategoryDiagnosticRow] = []
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(["Provider", "Parsed", "Rejected", "Stored", "Returned", "Displayed"], id: \.self) { Text($0).font(Typography.eyebrow).foregroundStyle(ColorTokens.textSecondary) }
                    }
                    ForEach(rows) { r in
                        GridRow {
                            Text(r.title).font(Typography.captionMedium).gridColumnAlignment(.leading)
                            Text(r.provider.map(String.init) ?? "–"); Text(r.parsed.map(String.init) ?? "–"); Text("\(r.rejected)")
                            Text("\(r.stored)"); Text("\(r.returned)"); Text("\(r.displayed)")
                        }.font(Typography.mono)
                    }
                }
                ForEach(rows.filter { !$0.rejectedReasons.isEmpty || $0.note != nil }) { r in
                    ForEach(r.rejectedReasons.prefix(3), id: \.self) { Text("\(r.title): \($0)").font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                    if let n = r.note { Text("\(r.title): \(n)").font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                }
                if let origin = rows.first?.origin { Text(origin).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                if let error { Text(error).font(Typography.caption).foregroundStyle(ColorTokens.warning) }
                HStack {
                    SecondaryButton(title: checking ? "Checking…" : "Check with provider", symbol: "arrow.triangle.2.circlepath") { Task { await liveCheck() } }.disabled(checking)
                    SecondaryButton(title: "Copy report", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CategoryDiagnosticsService.text(rows, playlist: source.name), forType: .string)
                    }.disabled(rows.isEmpty)
                }
            }.padding(.top, 6)
        } label: { Text("Folders check").font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary) }
        .task(id: "\(state.catalogVersion)-\(open)-\(settings.hideEmptyFolders)") { if open { load() } }
    }

    private func load() {
        guard let c = container else { return }
        rows = (try? c.categoryDiagnostics.report(sourceID: source.id, hideEmpty: settings.hideEmptyFolders)) ?? []
    }

    private func liveCheck() async {
        guard let c = container else { return }
        checking = true; error = nil
        do { rows = try await c.categoryDiagnostics.liveCheck(source: source, hideEmpty: settings.hideEmptyFolders) }
        catch { self.error = "Couldn't reach the provider: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)" }
        checking = false
    }
}
