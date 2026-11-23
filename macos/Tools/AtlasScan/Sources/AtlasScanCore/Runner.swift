import Foundation

public enum Runner {
    /// Roots scanned by default, relative to the repository root. Tests, Generated, Playback and the Atlas folder itself are skipped.
    public static let defaultRoots = ["macos/Sources/REDDY/Features", "macos/Sources/REDDY/DesignSystem", "macos/Sources/REDDY/Application", "ios/StreamSetu"]
    public static let iosRoots = ["ios/StreamSetu"]
    static let skippedComponents: Set<String> = ["Tests", "Generated", "Playback", "Atlas", "Resources"]

    public static func swiftFiles(under root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension == "swift" {
            if u.pathComponents.contains(where: skippedComponents.contains) { continue }
            out.append(u)
        }
        return out.sorted { $0.path < $1.path }
    }

    public static func folder(of relative: String) -> String {
        let dirs = Array(relative.split(separator: "/").map(String.init).dropLast())
        if dirs.first == "macos", let i = dirs.firstIndex(of: "REDDY") { return "macos/" + dirs[(i + 1)...].prefix(2).joined(separator: "/") }
        if dirs.first == "ios" { return "ios/" + dirs.dropFirst(2).prefix(1).joined(separator: "/") }
        return dirs.joined(separator: "/")
    }

    public static func scan(repo: URL, files: [URL]) -> (hits: [Hit], count: Int) {
        let results = files.map { u -> [Hit] in
            guard let src = try? String(contentsOf: u, encoding: .utf8) else { return [] }
            let rel = u.standardizedFileURL.path.hasPrefix(repo.standardizedFileURL.path + "/") ? String(u.standardizedFileURL.path.dropFirst(repo.standardizedFileURL.path.count + 1)) : u.lastPathComponent
            return Scanner.scan(source: src, file: rel, folder: folder(of: rel))
        }
        return (results.flatMap { $0 }, files.count)
    }
}
