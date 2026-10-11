import Foundation

struct RequestBuilder: Sendable {
    var config: NetworkConfiguration = .default

    func get(_ url: URL, etag: String? = nil, lastModified: String? = nil, userAgent: String? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: config.requestTimeout)
        r.setValue(userAgent ?? config.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { r.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        return r
    }
}
