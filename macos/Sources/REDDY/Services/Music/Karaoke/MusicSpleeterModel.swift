import CoreML
import Foundation

/// Which family a separation model belongs to. Models saved before this existed have no family and are the spectrogram-in, spectrogram-out kind.
enum MusicStemFamily: String, Sendable, Codable, Hashable {
    case mdx, spleeter
}

/// A model that takes a waveform chunk and returns its vocals itself, doing its own spectrogram work around the network.
/// The engine still owns chunking, blending and the vocals-to-instrumental step.
protocol MusicWaveformStemModel: MusicStemModel {
    /// `left` and `right` hold exactly `layout.stft.chunk` samples. The result has the same length and holds the vocals only.
    func estimateVocals(left: [Float], right: [Float], stft: MusicSTFT) throws -> (left: [Float], right: [Float])
}

/// Turns a magnitude spectrogram window into vocal and accompaniment masks. Core ML does this in the app; tests use a stand-in.
protocol MusicSpleeterMaskPredicting: Sendable {
    /// `magnitude` is [2, T, F] (channel, frame, bin). The result is [4, T, F]: vocal masks for both channels, then accompaniment masks.
    func masks(magnitude: [Float]) throws -> [Float]
}

/// The published two-stem separator: a pair of U-Nets that each estimate a soft mask from the magnitude spectrogram, then a ratio of the two
/// squared estimates (a Wiener-style normalisation) is applied to the complex spectrum of the song. The network only sees the lowest
/// 1024 bins (about 11 kHz); the published model leaves everything above that out of the vocals, so here it stays in the instrumental.
final class SpleeterStemModel: MusicWaveformStemModel, Sendable {
    /// 4096-point transform, hop 1024, 512-frame windows, 1024 bins.
    static let config = MusicSTFTConfig(nFFT: 4096, hop: 1024, dimF: 1024, dimT: 512, compensate: 1)
    static let defaultLayout = MusicStemLayout(stft: config, stem: .vocals, sampleRate: 44_100)
    /// The small constant of the reference normalisation.
    static let epsilon: Float = 1e-10

    let layout = SpleeterStemModel.defaultLayout
    private let predictor: MusicSpleeterMaskPredicting

    init(predictor: MusicSpleeterMaskPredicting) { self.predictor = predictor }

    convenience init(compiledURL: URL, processor: MusicKaraokeProcessor) throws {
        self.init(predictor: try MusicSpleeterCoreMLPredictor(compiledURL: compiledURL, processor: processor))
    }

    /// Present only to satisfy the protocol: this family never goes through the tensor path.
    func separate(_ tensor: [Float]) throws -> [Float] { throw MusicStemModelError.badLayout }

    /// The reference ratio mask for one bin: the vocal share of the squared estimates.
    static func ratio(vocalMask: Float, accompanimentMask: Float, power: Float) -> Float {
        let v = vocalMask * vocalMask * power, a = accompanimentMask * accompanimentMask * power
        return (v + epsilon / 2) / (v + a + epsilon)
    }

    func estimateVocals(left: [Float], right: [Float], stft: MusicSTFT) throws -> (left: [Float], right: [Float]) {
        let cfg = Self.config
        guard stft.config == cfg, left.count == cfg.chunk, right.count == cfg.chunk else { throw MusicStemModelError.badLayout }
        let frames = cfg.dimT, bins = cfg.dimF, plane = frames * bins
        let spectra = [stft.forward(left), stft.forward(right)]
        var magnitude = [Float](repeating: 0, count: 2 * plane)
        for (c, s) in spectra.enumerated() {
            for t in 0..<frames {
                let dst = c * plane + t * bins
                for f in 0..<bins {
                    let i = f * frames + t
                    magnitude[dst + f] = (s.re[i] * s.re[i] + s.im[i] * s.im[i]).squareRoot()
                }
            }
        }
        let masks = try predictor.masks(magnitude: magnitude)
        guard masks.count == 4 * plane else { throw MusicStemModelError.badOutput }
        var out: [[Float]] = []
        for (c, s) in spectra.enumerated() {
            var re = [Float](repeating: 0, count: cfg.bins * frames), im = re
            for t in 0..<frames {
                let m = c * plane + t * bins
                for f in 0..<bins {
                    let i = f * frames + t
                    let power = s.re[i] * s.re[i] + s.im[i] * s.im[i]
                    let r = Self.ratio(vocalMask: masks[m + f], accompanimentMask: masks[2 * plane + m + f], power: power)
                    guard r.isFinite else { continue }
                    re[i] = s.re[i] * r; im[i] = s.im[i] * r
                }
            }
            out.append(stft.inverse(re: re, im: im))
        }
        return (out[0], out[1])
    }
}

/// Runs the compiled network. MLModel is not declared thread safe, so calls are serialised.
final class MusicSpleeterCoreMLPredictor: MusicSpleeterMaskPredicting, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    init(compiledURL: URL, processor: MusicKaraokeProcessor) throws {
        guard FileManager.default.fileExists(atPath: compiledURL.path) else { throw MusicStemModelError.missingModel }
        let config = MLModelConfiguration()
        config.computeUnits = MusicKaraokeProcessor.coreMLAvailable ? processor.computeUnits : .cpuOnly
        do { model = try MLModel(contentsOf: compiledURL, configuration: config) }
        catch { throw MusicStemModelError.loadFailed(error.localizedDescription) }
        guard let i = model.modelDescription.inputDescriptionsByName.keys.sorted().first,
              let o = model.modelDescription.outputDescriptionsByName.keys.sorted().first else { throw MusicStemModelError.badLayout }
        inputName = i; outputName = o
    }

    func masks(magnitude: [Float]) throws -> [Float] {
        let c = SpleeterStemModel.config
        let plane = c.dimT * c.dimF
        guard magnitude.count == 2 * plane else { throw MusicStemModelError.badLayout }
        let input = try MLMultiArray(shape: [1, 2, NSNumber(value: c.dimT), NSNumber(value: c.dimF)], dataType: .float32)
        let expected = [2 * plane, plane, c.dimF, 1]
        if input.strides.map(\.intValue) == expected {
            magnitude.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                input.dataPointer.copyMemory(from: base, byteCount: src.count * MemoryLayout<Float>.size)
            }
        } else {
            for (i, v) in magnitude.enumerated() { input[i] = NSNumber(value: v) }
        }
        lock.lock(); defer { lock.unlock() }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]))
        guard let out = result.featureValue(for: outputName)?.multiArrayValue, out.count == 4 * plane else { throw MusicStemModelError.badOutput }
        let dims = out.shape.map(\.intValue), strides = out.strides.map(\.intValue)
        guard dims.count == 4, dims[0] == 1, dims[1] == 4 else { throw MusicStemModelError.badOutput }
        var flat = [Float](repeating: 0, count: 4 * plane)
        if out.dataType == .float32, strides[3] == 1, strides[2] == dims[3], strides[1] == dims[2] * dims[3] {
            out.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<flat.count { flat[i] = p[i] } }
        } else {
            // Odd strides or half precision: slower but correct.
            var k = 0
            for b in 0..<dims[1] { for cc in 0..<dims[2] { for d in 0..<dims[3] {
                flat[k] = out[b * strides[1] + cc * strides[2] + d * strides[3]].floatValue; k += 1
            } } }
        }
        return flat
    }
}

// MARK: Included model

/// The model that ships inside the app. Its files are produced by `Scripts/fetch-karaoke-model.sh` and copied in by the release build.
enum MusicKaraokeBundledModels {
    static let folderName = "Models"
    static let spleeterFile = "SpleeterVocals2.mlmodelc"
    static let licenseName = "MIT licence"

    static func spleeter(sizeBytes: Int64) -> MusicKaraokeInstalledModel {
        MusicKaraokeInstalledModel(id: "spleeter-2stems", name: "Spleeter", tier: .light, compiledName: spleeterFile, sizeBytes: sizeBytes,
                                   layout: SpleeterStemModel.defaultLayout, family: .spleeter, isBundled: true, licenseName: licenseName)
    }

    /// `resources` is the app's resource folder. A build without the model has no such folder and offers nothing.
    static func found(in resources: URL?) -> [MusicKaraokeInstalledModel] {
        guard let dir = resources?.appendingPathComponent(folderName, isDirectory: true) else { return [] }
        let url = dir.appendingPathComponent(spleeterFile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path) else { return [] }
        return [spleeter(sizeBytes: folderSize(url))]
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in walk { total += Int64((try? f.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0) }
        return total
    }
}
