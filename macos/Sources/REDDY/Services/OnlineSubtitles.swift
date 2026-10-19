import Foundation

/// Subtitles from OpenSubtitles. It needs the person's own free API key, and their free account name and password to download. They are kept in the Keychain on this
/// device and sent only to opensubtitles.com when the person asks for subtitles.
struct OnlineSubtitles: Sendable {
    struct Hit: Identifiable, Hashable, Sendable { let fileID: Int; let label: String; var id: Int { fileID } }
    struct Account: Sendable { var key = "", user = "", password = ""; var isComplete: Bool { !key.isEmpty && !user.isEmpty && !password.isEmpty } }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    let account: Account
    private let base = "https://api.opensubtitles.com/api/v1"

    private func request(_ path: String, token: String? = nil, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw Failure.message("That address is not valid.") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(account.key, forHTTPHeaderField: "Api-Key"); r.setValue("StreamSetu v1", forHTTPHeaderField: "User-Agent"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return r
    }

    /// Subtitles for a title in a language ("en", "hi", "te"…), most downloaded first.
    func search(title: String, year: Int?, language: String, season: Int? = nil, episode: Int? = nil) async throws -> [Hit] {
        let clean = title.replacingOccurrences(of: #"\(.*?\)|\[.*?\]"#, with: " ", options: .regularExpression).split(separator: " ").joined(separator: " ")
        var q = "/subtitles?query=\(clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean)&languages=\(language.isEmpty ? "en" : language)&order_by=download_count"
        if let year { q += "&year=\(year)" }
        if let season, let episode { q += "&type=episode&season_number=\(season)&episode_number=\(episode)" }
        let (data, response) = try await URLSession.shared.data(for: request(q))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.message(http.statusCode == 401 || http.statusCode == 403 ? "The API key was not accepted." : "OpenSubtitles answered \(http.statusCode).")
        }
        let rows = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return rows.prefix(15).compactMap { row in
            guard let a = row["attributes"] as? [String: Any], let file = (a["files"] as? [[String: Any]])?.first, let id = file["file_id"] as? Int else { return nil }
            let release = (a["release"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (file["file_name"] as? String) ?? "Subtitles"
            let downloads = (a["download_count"] as? Int).flatMap { $0 > 0 ? "\($0) downloads" : nil }
            return Hit(fileID: id, label: [release, downloads].compactMap { $0 }.joined(separator: "  ·  "))
        }
    }

    /// Downloads one subtitle to a temporary file and returns it.
    func download(_ hit: Hit) async throws -> URL {
        let (loginData, loginResponse) = try await URLSession.shared.data(for: request("/login", body: ["username": account.user, "password": account.password]))
        guard (loginResponse as? HTTPURLResponse)?.statusCode == 200, let token = (try JSONSerialization.jsonObject(with: loginData) as? [String: Any])?["token"] as? String
        else { throw Failure.message("OpenSubtitles did not accept the account name and password.") }
        let (linkData, linkResponse) = try await URLSession.shared.data(for: request("/download", token: token, body: ["file_id": hit.fileID]))
        if let http = linkResponse as? HTTPURLResponse, http.statusCode == 406 { throw Failure.message("The daily download limit of the free account is used up.") }
        guard (linkResponse as? HTTPURLResponse)?.statusCode == 200, let link = (try JSONSerialization.jsonObject(with: linkData) as? [String: Any])?["link"] as? String, let url = URL(string: link)
        else { throw Failure.message("OpenSubtitles sent no file.") }
        let (file, _) = try await URLSession.shared.data(from: url)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(hit.fileID).srt")
        try file.write(to: out)
        return out
    }
}

extension OnlineSubtitles.Account {
    private static let ref = "opensubtitles"
    static func load(from store: CredentialStore) -> OnlineSubtitles.Account {
        guard let c = try? store.load(ref: ref) else { return OnlineSubtitles.Account() }
        return OnlineSubtitles.Account(key: c.url ?? "", user: c.username ?? "", password: c.password ?? "")
    }
    func save(to store: CredentialStore) {
        if key.isEmpty && user.isEmpty && password.isEmpty { try? store.delete(ref: Self.ref) }
        else { try? store.save(Credentials(username: user, password: password, url: key), ref: Self.ref) }
    }
}
