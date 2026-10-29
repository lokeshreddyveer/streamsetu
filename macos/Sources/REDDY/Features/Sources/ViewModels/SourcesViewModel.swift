import SwiftUI
import Observation

enum AddSourceKind: String, CaseIterable, Identifiable {
    case xtream = "Xtream", m3uURL = "M3U or JSON link", m3uFile = "M3U or JSON file", stalker = "Stalker / MAG portal", jellyfin = "Jellyfin", emby = "Emby", plex = "Plex", hdhomerun = "HDHomeRun", tvheadend = "TVHeadend", enigma2 = "Enigma2 receiver", stream = "Single stream"
    var id: String { rawValue }
    /// What the Type menu offers. The App Store build leaves out the Stalker / MAG portal type (it presents a set-top-box identity, and is
    /// mostly used with services that are not licensed); every other build keeps it.
    static var offered: [AddSourceKind] {
        #if STREAMSETU_APPSTORE
        allCases.filter { $0 != .stalker }
        #else
        allCases
        #endif
    }
    /// Types that ask for a server, a user name and a password.
    var usesLogin: Bool { self == .xtream || self == .jellyfin || self == .emby || self == .tvheadend || self == .enigma2 }
}

@MainActor @Observable
final class AddSourceViewModel {
    var kind: AddSourceKind = .xtream
    var name = ""
    var server = ""
    var username = ""
    var password = ""
    var url = ""
    var fileURL: URL?
    var isWorking = false
    var error: String?
    /// Short note about what the pasted address was taken for.
    var detectionNote: String?

    /// The address and login the form would save, in one place for the warning below.
    private var addressToSave: String {
        switch kind { case .m3uURL, .stream: url; case .m3uFile: ""; default: server }
    }
    private var savesALogin: Bool {
        switch kind {
        case .xtream, .jellyfin, .emby, .tvheadend, .enigma2: !username.isEmpty || !password.isEmpty
        case .plex: !password.isEmpty
        default: false
        }
    }
    /// The address and kind the person has already agreed to save over plain HTTP; changing either asks again.
    private var acceptedPlainHTTPFor: String?
    private var acceptanceKey: String { "\(kind.rawValue)|\(addressToSave)" }

    /// Set when a login is about to be saved for a server that does not use HTTPS (and is not on this network): the screens ask first.
    var plainHTTPWarning: String? {
        guard acceptedPlainHTTPFor != acceptanceKey else { return nil }
        return ProviderSecurity.plainHTTPWarning(address: addressToSave, hasLogin: savesALogin)
    }
    func acceptPlainHTTP() { acceptedPlainHTTPFor = acceptanceKey }

    /// Fills the form from one pasted address. The person still reviews it and presses Add.
    func paste(_ text: String) {
        guard let d = SourceDetector.detect(text) else { detectionNote = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "That doesn't look like an address."; return }
        kind = d.kind; server = d.server; url = d.url
        if !d.username.isEmpty { username = d.username }
        if !d.password.isEmpty { password = d.password }
        detectionNote = d.note
    }

    var canSubmit: Bool {
        switch kind {
        case .tvheadend, .enigma2: !server.trimmingCharacters(in: .whitespaces).isEmpty
        case .stream: !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .xtream, .jellyfin, .emby: !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
        case .plex: !server.trimmingCharacters(in: .whitespaces).isEmpty && !password.trimmingCharacters(in: .whitespaces).isEmpty
        case .stalker: !server.trimmingCharacters(in: .whitespaces).isEmpty && StalkerMapper.normalizedMAC(username) != nil
        case .hdhomerun: !server.trimmingCharacters(in: .whitespaces).isEmpty
        case .m3uURL: !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .m3uFile: fileURL != nil
        }
    }

    #if os(macOS)
    func chooseFile() { if let u = WindowManager.chooseFile(types: ["m3u", "m3u8", "json"], prompt: "Import") { fileURL = u; if name.isEmpty { name = u.deletingPathExtension().lastPathComponent } } }
    #endif

    /// Validates, stores credentials in the Keychain and starts the first sync.
    func submit(container: AppContainer) async -> PlaylistSource? {
        guard canSubmit, !isWorking else { return nil }
        isWorking = true; error = nil
        defer { isWorking = false }
        let uc = AddSourceUseCase(sources: container.sources, sync: container.sync)
        do {
            switch kind {
            case .xtream: return try await uc.xtream(name: name, server: server, username: username, password: password)
            case .jellyfin: return try await uc.mediaServer(.jellyfin, name: name, server: server, username: username, password: password)
            case .emby: return try await uc.mediaServer(.emby, name: name, server: server, username: username, password: password)
            case .plex: return try await uc.plex(name: name, server: server, token: password)
            case .stalker: return try await uc.stalker(name: name, portal: server, mac: username)
            case .hdhomerun: return try await uc.hdhomerun(name: name, host: server)
            case .tvheadend: return try await uc.tvheadend(name: name, server: server, username: username, password: password)
            case .enigma2: return try await uc.enigma2(name: name, server: server, username: username, password: password)
            case .stream: return try await uc.stream(name: name, url: url)
            case .m3uURL: return try await uc.m3u(name: name, url: url)
            case .m3uFile: return try await uc.m3uFile(name: name, file: fileURL!)
            }
        } catch {
            self.error = CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return nil
        }
    }
}
