import Foundation
import os
#if os(macOS)
import AppKit
#endif

/// A running diary of what Music is doing, kept on this Mac only (`Logs/music-debug.log`, 1.5 MB, one older file kept) and mirrored to the system log. It is on in every build so a problem
/// that "just stops working" can be read afterwards: what was tapped, what the page decided, what each source answered, what failed. It holds ids, titles and counts, never a key, a
/// password or a listening summary. Each line: time, area, message.
enum MusicDebugLog {
    private static let queue = DispatchQueue(label: "app.streamsetu.musicdebuglog", qos: .utility)
    private static let logger = Logger(subsystem: "app.streamsetu.mac", category: "music")
    private static let maxBytes = 1_500_000
    private static let formatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("REDDY/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("music-debug.log")
    }

    /// `MusicDebugLog.log("home", "built \(n) shelves")`. The message is only built when the line is written.
    static func log(_ area: String, _ message: @autoclosure @escaping @Sendable () -> String) {
        let now = Date()
        queue.async {
            let text = message()
            logger.debug("[\(area, privacy: .public)] \(text, privacy: .public)")
            let line = formatter.string(from: now) + "  [" + area + "] " + text + "\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let u = url
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int, size > maxBytes {
            let old = u.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: u, to: old)
        }
        if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}

#if os(macOS)
/// Writes down where every left click lands and what is under it (the view that took it, and the chain above it), so "the button does nothing" can be told apart from "the click never
/// reached the button". One monitor for the whole app, installed once.
@MainActor enum MusicClickProbe {
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if let w = event.window, w.isKeyWindow || true, let content = w.contentView {
                let p = event.locationInWindow
                let hit = content.hitTest(content.convert(p, from: nil))
                var chain: [String] = []
                var v: NSView? = hit
                while let x = v, chain.count < 6 {
                    let label = x.accessibilityLabel().map { " “\($0.prefix(30))”" } ?? ""
                    chain.append(String(describing: type(of: x)).split(separator: "<").first.map(String.init).map { String($0.suffix(28)) } ?? "?" + label)
                    v = x.superview
                }
                let key = w.isKeyWindow ? "key" : "notKey"
                let line = "click at (\(Int(p.x)),\(Int(w.contentLayoutRect.height - p.y))) window \(Int(w.frame.width))x\(Int(w.frame.height)) \(key) hit: " + chain.joined(separator: " < ")
                MusicDebugLog.log("click", line)
            }
            return event
        }
    }
}
#endif
