import Foundation
import CoreGraphics

enum BufferingMode: String, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case lowLatency = "Low latency (live)"
    case standard = "Standard"
    case large = "Large buffer"
    var id: String { rawValue }

    /// How far behind the live edge AVPlayer should stay on live HLS (nil = let the system decide).
    var liveEdgeOffsetSeconds: Double? {
        switch self { case .automatic: nil; case .lowLatency: 3; case .standard: 10; case .large: 24 }
    }

    /// Seconds of media to keep ahead for AVPlayer (0 = let the system decide).
    var forwardBufferSeconds: Double {
        switch self { case .automatic: 0; case .lowLatency: 2; case .standard: 8; case .large: 30 }
    }
}

struct QualityOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let height: Int?
    let peakBitRate: Double?
}

enum AudioProcessingMode: String, Sendable, CaseIterable, Identifiable {
    case off = "Off", standard = "Standard", nightMode = "Night Mode"
    var id: String { rawValue }
}

/// One interface for every engine. The player UI never touches AVPlayer or libmpv directly.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var capabilities: PlaybackCapabilities { get }
    var state: PlaybackState { get }
    /// Emits every state change; consumers need not poll.
    var stateUpdates: AsyncStream<PlaybackState> { get }
    var position: TimeInterval { get }
    var duration: TimeInterval? { get }
    var metrics: PlaybackMetrics { get }
    var bufferingMode: BufferingMode { get set }
    /// Applies only to adaptive (HLS) streams that offer several variants.
    var qualityPreference: VideoQualityPreference { get set }
    /// Last HTTP status the stream endpoint returned, when known (used to classify failures).
    var lastHTTPStatus: Int? { get }

    func load(_ request: PlaybackRequest) async throws
    func play() async throws
    func pause()
    func stop()
    func seek(to position: TimeInterval) async throws

    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func setRate(_ rate: Double)

    func availableAudioTracks() -> [AudioTrack]
    func availableSubtitleTracks() -> [SubtitleTrack]
    func selectAudioTrack(id: String?)
    func selectSubtitleTrack(id: String?)
    func applySubtitleStyle(_ style: SubtitleStyle)
    /// Current frame, where the stream and engine allow it.
    func screenshot() -> CGImage?

    /// Variants the stream really offers (HLS renditions). Empty for single-quality streams.
    func qualityOptions() -> [QualityOption]
    func selectQuality(id: String?)
    var selectedQualityID: String? { get }

    /// Only meaningful when `capabilities` says the engine supports them.
    func setAudioDelay(_ seconds: Double)
    func setAudioProcessing(_ mode: AudioProcessingMode)
    func setSubtitleDelay(_ seconds: Double)
    /// Loads a subtitle file for the current stream and selects it. Returns false if the engine can't.
    func addSubtitleFile(_ url: URL) -> Bool
    /// End of what is buffered, in the stream's own time, when the engine keeps a rewindable live buffer. Nil otherwise.
    var liveBufferEnd: TimeInterval? { get }
    func setPicture(_ picture: PictureAdjustments)
    /// The file's chapters, when it has any and the engine can list them.
    func chapters() -> [PlaybackChapter]
    /// Repeats the part of the stream between two positions (nil clears it).
    func setLoop(start: Double?, end: Double?)
    /// Moves one frame forward or back and pauses.
    func frameStep(forward: Bool)
}

struct PlaybackChapter: Identifiable, Equatable, Sendable {
    let time: Double
    let title: String
    var id: Double { time }
}

extension PlaybackEngine {
    func chapters() -> [PlaybackChapter] { [] }
    func setLoop(start: Double?, end: Double?) {}
    func frameStep(forward: Bool) {}
}

/// Colour controls, each from −100 to +100 (0 = unchanged). Only MPV can apply them.
struct PictureAdjustments: Equatable, Sendable, Codable {
    var brightness = 0, contrast = 0, saturation = 0, gamma = 0, hue = 0
    var isDefault: Bool { self == PictureAdjustments() }
    static let range = -100...100
    func clamped() -> PictureAdjustments {
        func c(_ v: Int) -> Int { min(Self.range.upperBound, max(Self.range.lowerBound, v)) }
        return PictureAdjustments(brightness: c(brightness), contrast: c(contrast), saturation: c(saturation), gamma: c(gamma), hue: c(hue))
    }
}

/// How MPV maps high-dynamic-range video onto a normal display.
enum HDRToneMapping: String, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic", bt2390 = "BT.2390", hable = "Hable", mobius = "Mobius", reinhard = "Reinhard", clip = "Clip"
    var id: String { rawValue }
    var mpvValue: String {
        switch self { case .automatic: "auto"; case .bt2390: "bt.2390"; case .hable: "hable"; case .mobius: "mobius"; case .reinhard: "reinhard"; case .clip: "clip" }
    }
    var explanation: String {
        switch self {
        case .automatic: "MPV chooses. Recommended."
        case .bt2390: "The broadcast standard curve. Natural highlights."
        case .hable: "Filmic: punchy contrast, a little darker overall."
        case .mobius: "Keeps most of the picture unchanged and only compresses the brightest highlights."
        case .reinhard: "Smooth and bright, with softer contrast."
        case .clip: "No compression: the brightest parts clip to white."
        }
    }
}

extension PlaybackEngine {
    func screenshot() -> CGImage? { nil }
    func qualityOptions() -> [QualityOption] { [] }
    func selectQuality(id: String?) {}
    var selectedQualityID: String? { nil }
    func setAudioDelay(_ seconds: Double) {}
    func setAudioProcessing(_ mode: AudioProcessingMode) {}
    func setSubtitleDelay(_ seconds: Double) {}
    func addSubtitleFile(_ url: URL) -> Bool { false }
    var liveBufferEnd: TimeInterval? { nil }
    func setPicture(_ picture: PictureAdjustments) {}
}
