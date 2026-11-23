import Foundation
import os

#if DEBUG
/// Debug builds only: a record of the hosts the address policy refused or sent off-site, so a sign-in or content host that a service really
/// needs can be found while using a Debug build. It keeps the host name and nothing else: never a path, query, fragment, cookie or credential.
/// Read it with: log stream --level debug --predicate 'subsystem == "app.streamsetu.hub" && category == "blocked-host"'
enum DebugHostLog {
    struct Entry: Equatable { let service: String; let host: String; let decision: String; let mainFrame: Bool }

    private static let logger = Logger(subsystem: "app.streamsetu.hub", category: "blocked-host")
    nonisolated(unsafe) private static var recent: [Entry] = []
    private static let lock = NSLock()
    static let capacity = 200

    static func record(service: ProviderID, url: URL?, decision: ProviderURLPolicy.Decision, isMainFrame: Bool) {
        guard decision != .allowInApp, let host = url?.host?.lowercased(), !host.isEmpty else { return }
        let label = decision == .block ? "blocked" : "off-site"
        lock.lock(); recent.append(Entry(service: service.rawValue, host: host, decision: label, mainFrame: isMainFrame)); if recent.count > capacity { recent.removeFirst(recent.count - capacity) }; lock.unlock()
        logger.debug("\(service.rawValue, privacy: .public) \(label, privacy: .public) \(isMainFrame ? "main" : "sub", privacy: .public) host=\(host, privacy: .public)")
    }

    static var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return recent }
    static func reset() { lock.lock(); recent = []; lock.unlock() }
}
#endif
