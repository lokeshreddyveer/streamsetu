import CoreML
import Foundation

/// How a model wants to be fed and what it returns.
struct MusicStemLayout: Sendable, Hashable, Codable {
    var stft: MusicSTFTConfig
    var stem: MusicKaraokeStem
    var sampleRate: Double = 44_100
}

/// The slot a separation model plugs into. The input is one spectrogram chunk laid out as [1, 4, dimF, dimT]
/// (left real, left imaginary, right real, right imaginary); the output has the same shape and holds the estimate of `layout.stem`.
/// Implementations must be callable from a background thread, one call at a time.
protocol MusicStemModel: Sendable {
    var layout: MusicStemLayout { get }
    func separate(_ tensor: [Float]) throws -> [Float]
}

/// Which hardware runs the model. The processor is the safe default; the graphics chip is opt-in on Apple silicon.
enum MusicKaraokeProcessor: String, CaseIterable, Identifiable, Sendable, Codable {
    case cpu, coreML
    var id: String { rawValue }
    var title: String { self == .cpu ? "Processor" : "Core ML (graphics chip)" }
    var computeUnits: MLComputeUnits { self == .cpu ? .cpuOnly : .cpuAndGPU }
    /// Intel Macs stay on the processor.
    static var coreMLAvailable: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

enum MusicStemModelError: Error, Equatable, Sendable {
    case missingModel, badLayout, badOutput, loadFailed(String)
}

/// Runs a compiled Core ML model (`.mlmodelc`) that follows the tensor layout above.
/// MLModel is not declared thread safe, so every call is serialised behind a lock.
final class MusicCoreMLStemModel: MusicStemModel, @unchecked Sendable {
    let layout: MusicStemLayout
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    init(compiledURL: URL, layout: MusicStemLayout, processor: MusicKaraokeProcessor) throws {
        guard layout.stft.isValid else { throw MusicStemModelError.badLayout }
        guard FileManager.default.fileExists(atPath: compiledURL.path) else { throw MusicStemModelError.missingModel }
        let config = MLModelConfiguration()
        config.computeUnits = MusicKaraokeProcessor.coreMLAvailable ? processor.computeUnits : .cpuOnly
        do { model = try MLModel(contentsOf: compiledURL, configuration: config) }
        catch { throw MusicStemModelError.loadFailed(error.localizedDescription) }
        guard let i = model.modelDescription.inputDescriptionsByName.keys.sorted().first,
              let o = model.modelDescription.outputDescriptionsByName.keys.sorted().first else { throw MusicStemModelError.badLayout }
        inputName = i; outputName = o
        self.layout = layout
    }

    /// Turns a downloaded `.mlmodel` or `.mlpackage` into the compiled form Core ML loads, and moves it to `destination`.
    static func compile(_ source: URL, to destination: URL) async throws {
        let compiled = try await MLModel.compileModel(at: source)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: compiled, to: destination)
    }

    func separate(_ tensor: [Float]) throws -> [Float] {
        let c = layout.stft
        guard tensor.count == c.tensorCount else { throw MusicStemModelError.badLayout }
        let shape: [NSNumber] = [1, 4, NSNumber(value: c.dimF), NSNumber(value: c.dimT)]
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        let expected = [4 * c.dimF * c.dimT, c.dimF * c.dimT, c.dimT, 1]
        if input.strides.map(\.intValue) == expected {
            tensor.withUnsafeBufferPointer { src in
                input.dataPointer.copyMemory(from: src.baseAddress!, byteCount: src.count * MemoryLayout<Float>.size)
            }
        } else {
            for (i, v) in tensor.enumerated() { input[i] = NSNumber(value: v) }
        }
        lock.lock(); defer { lock.unlock() }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]))
        guard let out = result.featureValue(for: outputName)?.multiArrayValue, out.count == tensor.count else { throw MusicStemModelError.badOutput }
        var flat = [Float](repeating: 0, count: tensor.count)
        let outStrides = out.strides.map(\.intValue)
        if out.dataType == .float32, outStrides == expected {
            out.withUnsafeBufferPointer(ofType: Float.self) { p in
                for i in 0..<p.count { flat[i] = p[i] }
            }
        } else {
            // Half precision or odd strides: slow but correct.
            let dims = out.shape.map(\.intValue)
            guard dims.count == 4 else { throw MusicStemModelError.badOutput }
            var k = 0
            for a in 0..<dims[0] { for b in 0..<dims[1] { for cc in 0..<dims[2] { for d in 0..<dims[3] {
                let idx = a * outStrides[0] + b * outStrides[1] + cc * outStrides[2] + d * outStrides[3]
                flat[k] = out[idx].floatValue; k += 1
            } } } }
        }
        return flat
    }
}
