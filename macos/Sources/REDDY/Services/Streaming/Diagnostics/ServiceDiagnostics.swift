import Foundation
import Observation

/// Release-capable, privacy-safe record of what stopped a streaming service's page from loading. Kept in memory only: never written to disk,
/// never logged, gone when the app quits. An entry is a host name plus either "blocked" or a system error number. Never a path, query,
/// fragment, credential, cookie or page title.
@MainActor @Observable
final class ServiceDiagnostics {
    static let shared = ServiceDiagnostics()
    /// Entries kept per service; the oldest are dropped first.
    nonisolated static let capacity = 50

    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A main-frame address the host policy refused or sent off-site.
            case blocked
            /// A page-embedded (sub-frame) address the policy cancelled.
            case subframeBlocked
            /// A new-window request the app refused.
            case popupRefused
            /// A failed load: the system error number.
            case failure(code: Int)
            /// The page's web process ended; the host is the page the view was on.
            case processTerminated
            /// The main page answered with an HTTP status of 400 or more.
            case httpStatus(Int)
            /// A host in the redirect chain of one main-frame load, with its order (0 = where the load began). Host and number only.
            case redirectHop(index: Int)
            /// The provider's own server redirected this connection to its regional page (an exact host the definition names); it was not loaded.
            case providerRegionalPage
        }
        let host: String
        let kind: Kind
    }

    private var buffers: [ProviderID: [Entry]] = [:]

    func entries(for id: ProviderID) -> [Entry] { buffers[id] ?? [] }

    /// The lower-cased host of an address, or nil when it has none (about:, data:, javascript: ...). Nothing else of the address survives.
    nonisolated static func host(of url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        return h
    }

    /// A main-frame navigation the host policy refused or sent off-site.
    func recordBlocked(_ id: ProviderID, url: URL?) {
        guard let host = Self.host(of: url) else { return }
        append(Entry(host: host, kind: .blocked), to: id)
    }

    func recordSubframeBlocked(_ id: ProviderID, url: URL?) {
        guard let host = Self.host(of: url) else { return }
        append(Entry(host: host, kind: .subframeBlocked), to: id)
    }

    func recordPopupRefused(_ id: ProviderID, url: URL?) {
        guard let host = Self.host(of: url) else { return }
        append(Entry(host: host, kind: .popupRefused), to: id)
    }

    func recordProcessTerminated(_ id: ProviderID, url: URL?) {
        guard let host = Self.host(of: url) else { return }
        append(Entry(host: host, kind: .processTerminated), to: id)
    }

    /// One host of a redirect chain, in order. The address is never kept: no path, query or fragment.
    func recordRedirectHop(_ id: ProviderID, host: String, index: Int) {
        guard !host.isEmpty else { return }
        append(Entry(host: host.lowercased(), kind: .redirectHop(index: index)), to: id)
    }

    func recordRegionalPage(_ id: ProviderID, host: String) {
        guard !host.isEmpty else { return }
        append(Entry(host: host.lowercased(), kind: .providerRegionalPage), to: id)
    }

    /// The hosts of the most recent redirect chain, in order (empty when none was seen).
    func lastRedirectChain(for id: ProviderID) -> [String] {
        let hops = entries(for: id).compactMap { e -> (Int, String)? in if case .redirectHop(let i) = e.kind { (i, e.host) } else { nil } }
        guard let start = hops.lastIndex(where: { $0.0 == 0 }) else { return [] }
        var out = [hops[start].1], next = 1
        for h in hops[(start + 1)...] where h.0 == next { out.append(h.1); next += 1 }
        return out
    }

    /// Only statuses of 400 or more are kept.
    func recordHTTPStatus(_ id: ProviderID, url: URL?, status: Int?) {
        guard let status, status >= 400, let host = Self.host(of: url) else { return }
        append(Entry(host: host, kind: .httpStatus(status)), to: id)
    }

    /// A failed load: the host (from the error's failing address, else the page's address) and the numeric error code.
    func recordFailure(_ id: ProviderID, error: Error, fallbackURL: URL?) {
        let ns = error as NSError
        let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard let host = Self.host(of: failing) ?? Self.host(of: fallbackURL) else { return }
        append(Entry(host: host, kind: .failure(code: ns.code)), to: id)
    }

    func clear(_ id: ProviderID) { buffers[id] = nil }
    func clearAll() { buffers = [:] }

    /// Distinct hosts, in first-seen order, one per line: the only thing the Copy button puts on the clipboard.
    func hostList(for id: ProviderID) -> String {
        var seen = Set<String>(), out: [String] = []
        for e in entries(for: id) where seen.insert(e.host).inserted { out.append(e.host) }
        return out.joined(separator: "\n")
    }

    private func append(_ e: Entry, to id: ProviderID) {
        var list = buffers[id] ?? []
        if list.last == e { return }                         // a redirect check repeats the same refusal
        list.append(e)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        buffers[id] = list
    }
}
