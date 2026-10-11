import Foundation
import Network

/// When a stream has not started after a while, finds out WHY without touching the stream itself: is the server's name blocked (a DNS
/// filter often answers 0.0.0.0), does it not resolve, or can nothing connect to it. Only a name lookup and a plain TCP connection are
/// made, never a request for the stream, so a provider's connection limit is not used up.
enum StartDiagnosis {
    /// Addresses a DNS blocker hands out instead of the real one: "nowhere" and loopback.
    static func isSinkhole(_ address: String) -> Bool {
        let a = address.lowercased()
        return a == "0.0.0.0" || a == "::" || a == "::1" || a.hasPrefix("127.")
    }

    static func diagnose(_ url: URL, patience: TimeInterval = 6) async -> PlaybackError? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        // A name that is already an address cannot be blocked by DNS; only check that it connects.
        let isLiteral = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        var port = url.port
        if port == nil { port = ["https": 443, "http": 80, "rtsp": 554, "rtmp": 1935, "rtmps": 443, "rtsps": 322][scheme] }
        if !isLiteral {
            switch await resolve(host, patience: patience) {
            case .failed: return PlaybackError(.nameLookup, detail: host)
            case .addresses(let list) where !list.isEmpty && list.allSatisfy(isSinkhole): return PlaybackError(.nameLookup, detail: host)
            default: break
            }
        }
        if let port, ["http", "https", "rtsp", "rtsps", "rtmp", "rtmps"].contains(scheme), !(await canConnect(host, port: port, patience: patience)) {
            return PlaybackError(.providerUnavailable, detail: host)
        }
        return nil
    }

    enum Lookup: Equatable { case addresses([String]), failed, timedOut }

    static func resolve(_ host: String, patience: TimeInterval) async -> Lookup {
        await withTaskGroup(of: Lookup.self) { group in
            group.addTask {
                await Task.detached { () -> Lookup in
                    var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
                    var res: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return .failed }
                    defer { freeaddrinfo(res) }
                    var out: [String] = []
                    var p: UnsafeMutablePointer<addrinfo>? = first
                    while let ai = p {
                        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: buf)) }
                        p = ai.pointee.ai_next
                    }
                    return .addresses(out)
                }.value
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000)); return .timedOut }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    static func canConnect(_ host: String, port: Int, patience: TimeInterval) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return true }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled: if once.take() { cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + patience) { if once.take() { conn.cancel(); cont.resume(returning: false) } }
        }
    }
}
