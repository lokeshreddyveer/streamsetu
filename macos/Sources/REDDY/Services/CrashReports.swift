import Foundation

/// Crash reports stay on the device. Nothing is sent anywhere: a person who wants to share one exports it themselves.
/// On iPhone and iPad the system hands crash diagnostics to the app (MetricKit) and, only if the person has agreed, they are kept here.
/// On a Mac the system already writes them to ~/Library/Logs/DiagnosticReports, and this lists the ones for this app.
enum CrashReports {
    struct Report: Identifiable, Equatable { let url: URL; let date: Date; var id: URL { url } }

    static var folder: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        #else
        StorageService.applicationSupport.appendingPathComponent("CrashReports", isDirectory: true)
        #endif
    }

    static func list(in dir: URL = folder) -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter(isOurs).compactMap { u in
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }.map { Report(url: u, date: $0) }
        }.sorted { $0.date > $1.date }
    }

    static func isOurs(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        #if os(macOS)
        return (n.hasPrefix("streamsetu") || n.hasPrefix("reddy")) && (n.hasSuffix(".ips") || n.hasSuffix(".crash"))
        #else
        return n.hasSuffix(".json")
        #endif
    }

    #if !os(macOS)
    /// Keeps one diagnostic payload as a file, named by when it arrived.
    @discardableResult
    static func save(_ json: Data, now: Date = Date(), in dir: URL = folder) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("crash-\(stamp).json")
        return (try? json.write(to: url, options: .atomic)) == nil ? nil : url
    }

    static func removeAll(in dir: URL = folder) { list(in: dir).forEach { try? FileManager.default.removeItem(at: $0.url) } }
    #endif
}
