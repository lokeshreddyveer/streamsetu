import Foundation

/// A plain-text trace of what playback is doing, printed only when the app is launched with STREAMSETU_TRACE=1 (a developer build with
/// its console attached). Off, it costs one boolean check. Everything printed goes through the credential redactor.
enum Trace {
    static let on = ProcessInfo.processInfo.environment["STREAMSETU_TRACE"] != nil
    private static let start = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard on else { return }
        print(String(format: "[TRACE +%7.2f] ", Date().timeIntervalSince(start)) + CredentialRedactor.redact(message()))
    }

    /// "https://host:8080/…/file.mkv" -> "https://host:8080/…/file.mkv" with the path squashed, so no login in a path is shown.
    static func describe(_ url: URL) -> String { "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.port.map { ":\($0)" } ?? "") .\(url.pathExtension.lowercased())" }
}
