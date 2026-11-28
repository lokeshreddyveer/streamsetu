import Foundation

/// What the app measured about how one recording sounds. Every number comes from the audio itself; none is read from tags or guessed from the artist.
struct SonicProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Section: Codable, Equatable, Sendable { var start: Double; var end: Double; var label: Label; var group: Int
        enum Label: String, Codable, Sendable { case intro, outro, section }
    }

    var version = SonicProfile.currentVersion
    /// Tempo in beats per minute and how sure the measurement is (0 to 1). Nil when the recording has no steady pulse.
    var bpm: Double?
    var bpmConfidence: Double = 0
    /// Key as a tonic (0 = C ... 11 = B) and mode, with confidence; nil when no clear key.
    var keyTonic: Int?
    var keyIsMinor = false
    var keyConfidence: Double = 0
    /// 0 relaxed to 1 energetic.
    var energy: Double = 0
    /// Average level in dB below full scale (a plain RMS level, not a broadcast loudness figure), the peak, and how far loud passages sit above quiet ones.
    var levelDB: Double = -60
    var peakDB: Double = -60
    var dynamicRangeDB: Double = 0
    /// Brightness: the average spectral centre in Hz.
    var brightnessHz: Double = 0
    /// Which of the beat-spacing bands carry the rhythm (eight values, sum 1).
    var rhythm: [Float] = []
    /// A fixed-length description of the sound used to find similar songs.
    var vector: [Float] = []
    var sections: [Section] = []
    /// Seconds of audio that were analysed.
    var analysedSeconds: Double = 0

    var energyClass: EnergyClass { energy < 0.35 ? .relaxed : (energy > 0.65 ? .energetic : .steady) }
    enum EnergyClass: String, Sendable { case relaxed, steady, energetic }

    private static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    var keyName: String? { keyTonic.map { Self.names[$0] + (keyIsMinor ? " minor" : " major") } }

    /// The Camelot wheel code ("8B"): same number or a neighbour on the same letter mix well.
    var camelot: String? {
        guard let t = keyTonic else { return nil }
        let major = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        return keyIsMinor ? "\(minor[t])A" : "\(major[t])B"
    }
}

/// A stored profile and what it belongs to.
struct SonicRecord: Codable, Equatable, Sendable {
    var key: String
    var stamp: Double          // the file's modification time when it was analysed
    var profile: SonicProfile
}

/// The measured facts a song's information sheet shows, as label and value pairs (empty when the song has not been analysed or the measure is not clear).
enum MusicSonicRows {
    static func rows(_ p: SonicProfile?) -> [MusicInfoRow] {
        guard let p else { return [] }
        var out: [MusicInfoRow] = []
        if let b = p.bpm, p.bpmConfidence > 0.15 { out.append(MusicInfoRow(label: Localized.string("Tempo"), value: Localized.string("%@ BPM", String(Int(b.rounded()))))) }
        if let k = p.keyName, p.keyConfidence > 0.1, let c = p.camelot { out.append(MusicInfoRow(label: Localized.string("Key"), value: k + " (" + c + ")")) }
        let energy: String
        switch p.energyClass { case .relaxed: energy = Localized.string("Relaxed"); case .steady: energy = Localized.string("Steady"); case .energetic: energy = Localized.string("Energetic") }
        out.append(MusicInfoRow(label: Localized.string("Energy"), value: energy))
        out.append(MusicInfoRow(label: Localized.string("Level"), value: Localized.string("%@ dB", String(Int(p.levelDB.rounded())))))
        out.append(MusicInfoRow(label: Localized.string("Dynamic range"), value: Localized.string("%@ dB", String(Int(p.dynamicRangeDB.rounded())))))
        return out
    }
}
