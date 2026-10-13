import Foundation

/// A plain-text trace of what playback is doing. It always goes to the local playback log; the console copy and the costly measurements
/// (frame brightness) need STREAMSETU_TRACE=1. Everything goes through the credential redactor.
enum Trace {
    static let on = ProcessInfo.processInfo.environment["STREAMSETU_TRACE"] != nil
    private static let start = Date()

    /// Every message goes into the local playback log (see PlaybackLog); it is also printed to the console when STREAMSETU_TRACE is set.
    static func log(_ message: @autoclosure () -> String) {
        let text = CredentialRedactor.redact(message())
        PlaybackLog.shared.append(text)
        if on { print(String(format: "[TRACE +%7.2f] ", Date().timeIntervalSince(start)) + text) }
    }

    /// "https://host:8080/…/file.mkv" -> "https://host:8080/…/file.mkv" with the path squashed, so no login in a path is shown.
    static func describe(_ url: URL) -> String { "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.port.map { ":\($0)" } ?? "") .\(url.pathExtension.lowercased())" }
}
