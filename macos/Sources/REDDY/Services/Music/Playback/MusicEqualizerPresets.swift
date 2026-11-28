import Foundation

/// The sixteen equalizer presets. Each is seven gains in dB for the seven bands in `MusicEqualizerMath.bandCentres`
/// (50, 125, 320, 800, 2000, 5000 and 12000 Hz). Names and values are this app's own, chosen by ear and checked on the response curve:
/// no preset boosts more than 6 dB anywhere, so the make-up gain and limiter never have to work hard.
struct MusicEqualizerPreset: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let gains: [Double]
}

enum MusicEqualizerPresets {
    static let all: [MusicEqualizerPreset] = [
        .init(id: "flat", title: "Flat", detail: "No change.", gains: [0, 0, 0, 0, 0, 0, 0]),
        .init(id: "warm", title: "Warm", detail: "Fuller low end, softer top.", gains: [3, 2, 1, 0, -0.5, -1.5, -2]),
        .init(id: "bright", title: "Bright", detail: "More air and detail.", gains: [-1, -0.5, 0, 0.5, 2, 3.5, 4]),
        .init(id: "bassLift", title: "Bass lift", detail: "More weight below 300 Hz.", gains: [5, 3.5, 1, 0, 0, 0, 0]),
        .init(id: "bassTrim", title: "Bass trim", detail: "Less rumble, for small speakers.", gains: [-5, -3, -1, 0, 0, 0, 0]),
        .init(id: "trebleLift", title: "Treble lift", detail: "More sparkle.", gains: [0, 0, 0, 0, 1, 3, 5]),
        .init(id: "trebleTrim", title: "Treble trim", detail: "Less hiss and edge.", gains: [0, 0, 0, 0, -1, -3, -5]),
        .init(id: "vocal", title: "Vocal focus", detail: "Brings voices forward.", gains: [-2, -1.5, -0.5, 1.5, 3, 1.5, -0.5]),
        .init(id: "speech", title: "Clear speech", detail: "For podcasts and talk.", gains: [-4, -3, 0, 2.5, 3.5, 1, -3]),
        .init(id: "loudness", title: "Loudness", detail: "Keeps bass and treble present at low volume.", gains: [5, 3, 0, -1, -0.5, 2.5, 4]),
        .init(id: "dance", title: "Dance", detail: "Punchy kick, crisp top.", gains: [4.5, 3, 0, -1, 0.5, 2.5, 3.5]),
        .init(id: "guitar", title: "Guitar", detail: "Body and bite for rock.", gains: [3, 2, -1, -0.5, 1.5, 3, 2]),
        .init(id: "lowEnd", title: "Low-end groove", detail: "Deep bass with a clean top.", gains: [5.5, 3.5, 0.5, -0.5, 0.5, 1.5, 2]),
        .init(id: "unplugged", title: "Unplugged", detail: "Natural strings and voices.", gains: [2, 1.5, 0.5, 0, 1.5, 2, 1.5]),
        .init(id: "classical", title: "Classical", detail: "Gentle lift at both ends.", gains: [2, 1, 0, 0, 0, 1.5, 2.5]),
        .init(id: "lateNight", title: "Late night", detail: "Quieter highs, steady bass.", gains: [2, 1, 0, 1, 0.5, -1.5, -3]),
    ]

    static func preset(id: String) -> MusicEqualizerPreset? { all.first { $0.id == id } }

    /// The preset whose seven gains equal `bands` to within 0.05 dB, or nil for a custom curve.
    static func matching(_ bands: [Double]) -> MusicEqualizerPreset? {
        guard bands.count == MusicEqualizerMath.bandCentres.count else { return nil }
        return all.first { p in zip(p.gains, bands).allSatisfy { abs($0 - $1) < 0.05 } }
    }
}
