import Foundation

/// Recordings of live channels: files kept on this Mac, named by what was recorded and when.
enum Recordings {
    nonisolated static var folder: URL {
        var url = StorageService.ensure(StorageService.applicationSupport.appendingPathComponent("Recordings", isDirectory: true))
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        let title: String
        let date: Date
        let bytes: Int64
        var id: URL { url }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// "News 24__20261017-211500.ts": the channel's name (made safe for a file), two underscores, and when it started.
    static func fileName(channel: String, at date: Date) -> String {
        let safe = channel.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }
        return String(safe).trimmingCharacters(in: .whitespaces) + "__" + stamp.string(from: date) + ".ts"
    }

    static func parse(fileName: String) -> (title: String, date: Date)? {
        let base = (fileName as NSString).deletingPathExtension
        guard let r = base.range(of: "__", options: .backwards), let d = stamp.date(from: String(base[r.upperBound...])) else { return nil }
        return (String(base[..<r.lowerBound]), d)
    }

    /// Everything recorded, newest first.
    static func all() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> Item? in
            guard url.pathExtension == "ts", let p = parse(fileName: url.lastPathComponent) else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return Item(url: url, title: p.title, date: p.date, bytes: size)
        }.sorted { $0.date > $1.date }
    }
}
