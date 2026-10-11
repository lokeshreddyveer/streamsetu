import OSLog

/// App-wide loggers. Never log raw stream URLs or credentials; use `CredentialRedactor` first.
enum Log {
    static let app = Logger(subsystem: "app.streamsetu.mac", category: "app")
    static let network = Logger(subsystem: "app.streamsetu.mac", category: "network")
    static let sync = Logger(subsystem: "app.streamsetu.mac", category: "sync")
    static let database = Logger(subsystem: "app.streamsetu.mac", category: "database")
    static let playback = Logger(subsystem: "app.streamsetu.mac", category: "playback")
}
