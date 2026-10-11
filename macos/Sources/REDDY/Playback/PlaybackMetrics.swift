import Foundation

struct PlaybackMetrics: Sendable, Equatable {
    var engine: PlaybackEngineKind = .avPlayer
    var container: StreamContainer = .unknown
    var host: String = ""
    var width = 0, height = 0
    var observedBitrate: Double = 0       // bits/s
    var indicatedBitrate: Double = 0
    var droppedFrames = 0
    var stallCount = 0
    var totalStallSeconds: Double = 0
    var bufferedAheadSeconds: Double = 0
    var startupSeconds: Double?
    var videoCodec: String?
    var audioCodec: String?
    var frameRate: Double?

    var resolution: String { width > 0 ? "\(width)×\(height)" : "—" }
    var bitrateText: String { observedBitrate > 0 ? String(format: "%.1f Mbps", observedBitrate / 1_000_000) : "—" }

    var summary: String {
        "\(engine.rawValue) · \(container.rawValue) · \(resolution) · \(bitrateText) · stalls \(stallCount) · dropped \(droppedFrames)"
    }
}
