import Foundation

struct XtreamAccount: Sendable, Hashable {
    let base: String
    let user: String
    let pass: String
    var headers = SourceHeaders()

    var epgURL: URL? {
        URL(string: "\(base)/xmltv.php?username=\(URLUtilities.encode(user))&password=\(URLUtilities.encode(pass))")
    }
}

/// Talks to `player_api.php`. Works on panels that have disabled `get.php`.
struct XtreamClient: Sendable {
    let account: XtreamAccount
    let http: HTTPClient

    private func url(_ action: String?, _ extra: [String: String] = [:]) throws -> URL {
        var q = "username=\(URLUtilities.encode(account.user))&password=\(URLUtilities.encode(account.pass))"
        if let action { q += "&action=\(action)" }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { q += "&\(k)=\(URLUtilities.encode(v))" }
        guard let u = URL(string: "\(account.base)/player_api.php?\(q)") else { throw NetworkError.invalidURL }
        return u
    }

    private func raw(_ action: String?, _ extra: [String: String] = [:], maxBytes: Int64? = nil) async throws -> Data {
        do {
            var request = http.builder.get(try url(action, extra), userAgent: "VLC/3.0.20 LibVLC/3.0.20")
            account.headers.apply(to: &request)
            return try await http.data(request, maxBytes: maxBytes ?? http.config.maxJSONBytes)
        } catch let e as NetworkError {
            if e.isAuthFailure { throw XtreamError.authFailed }
            throw e
        }
    }

    func accountInfo() async throws -> XtreamAccountDTO.UserInfo {
        let data = try await raw(nil, maxBytes: 2 * 1024 * 1024)
        guard let info = try? JSONDecoder().decode(XtreamAccountDTO.self, from: data).user_info else { throw XtreamError.authFailed }
        if info.auth?.string == "0" { throw XtreamError.authFailed }
        if let status = info.status?.string, !status.isEmpty, status.lowercased() != "active" { throw XtreamError.inactive(status) }
        return info
    }

    /// The account as the panel describes it, without judging it: an expired or disabled account still answers, and that answer is what the person wants to see.
    func accountDetails() async throws -> XtreamAccountDTO.UserInfo {
        let data = try await raw(nil, maxBytes: 2 * 1024 * 1024)
        guard let info = try? JSONDecoder().decode(XtreamAccountDTO.self, from: data).user_info else { throw XtreamError.authFailed }
        return info
    }

    /// Lists come back as `[...]`; many panels return `false`, `{}` or `null` when a section is empty.
    func list<T: Decodable>(_ action: String, _ extra: [String: String] = [:], as: T.Type = T.self) async throws -> [T] {
        try Self.decodeList(try await raw(action, extra), action: action)
    }

    static func decodeList<T: Decodable>(_ data: Data, action: String) throws -> [T] {
        if let arr = try? JSONDecoder().decode([T].self, from: data) { return arr }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if obj is NSNull || obj is Bool { return [] }
            if let d = obj as? [String: Any], d.isEmpty { return [] }
            if let d = obj as? [String: Any], d["user_info"] != nil || d["error"] != nil { throw XtreamError.authFailed }
        }
        throw XtreamError.invalidResponse("Unexpected list for \(action).")
    }

    /// Category lists, decoded one entry at a time: a single malformed entry (a `null`, a bare string) costs that entry,
    /// not the whole list. Returns how many entries the provider listed and why any were skipped.
    func categoryList(_ action: String) async throws -> (items: [XtreamCategoryDTO], listed: Int, rejected: [String]) {
        Self.decodeCategoryList(try await raw(action), action: action)
    }

    static func decodeCategoryList(_ data: Data, action: String) -> (items: [XtreamCategoryDTO], listed: Int, rejected: [String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return ([], 0, ["response was not JSON"]) }
        var elements: [Any]
        if let a = obj as? [Any] { elements = a }
        else if let d = obj as? [String: Any], !d.isEmpty, d["user_info"] == nil, d["error"] == nil { elements = Array(d.values) }   // some panels key the list by id
        else { return ([], 0, []) }                                                       // false / null / {} = genuinely empty
        let decoder = JSONDecoder()
        var items: [XtreamCategoryDTO] = [], rejected: [String] = []
        for (i, e) in elements.enumerated() {
            guard e is [String: Any], let data = try? JSONSerialization.data(withJSONObject: e),
                  let dto = try? decoder.decode(XtreamCategoryDTO.self, from: data) else { rejected.append("entry \(i + 1): not an object"); continue }
            items.append(dto)
        }
        return (items, elements.count, rejected)
    }

    func liveCategories() async throws -> [XtreamCategoryDTO] { try await list("get_live_categories") }
    func liveStreams() async throws -> [XtreamLiveDTO] { try await list("get_live_streams") }
    func vodCategories() async throws -> [XtreamCategoryDTO] { try await list("get_vod_categories") }
    func vodStreams() async throws -> [XtreamVODDTO] { try await list("get_vod_streams") }
    func seriesCategories() async throws -> [XtreamCategoryDTO] { try await list("get_series_categories") }
    func seriesList() async throws -> [XtreamSeriesDTO] { try await list("get_series") }

    func vodInfo(id: String) async throws -> XtreamVODInfoDTO {
        let data = try await raw("get_vod_info", ["vod_id": id], maxBytes: 8 * 1024 * 1024)
        do { return try JSONDecoder().decode(XtreamVODInfoDTO.self, from: data) }
        catch { throw XtreamError.invalidResponse("Unreadable movie details.") }
    }

    func seriesInfo(id: String) async throws -> XtreamSeriesInfoDTO {
        let data = try await raw("get_series_info", ["series_id": id], maxBytes: 16 * 1024 * 1024)
        do { return try JSONDecoder().decode(XtreamSeriesInfoDTO.self, from: data) }
        catch { throw XtreamError.invalidResponse("Unreadable series details.") }
    }
}
