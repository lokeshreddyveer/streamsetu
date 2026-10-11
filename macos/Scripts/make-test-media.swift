// Writes a short H.264 test video (moving bars, 5 s, 640x360) with no network and no external tools.
// usage: swift Scripts/make-test-media.swift /path/out.mp4
import AVFoundation
import CoreVideo

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "test.mp4")
try? FileManager.default.removeItem(at: out)
let w = 640, h = 360, fps = 30, seconds = 5
let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
writer.add(input)
writer.startWriting(); writer.startSession(atSourceTime: .zero)
for frame in 0..<(fps * seconds) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let b = buffer else { continue }
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let o = y * stride + x * 4
        let bar = ((x + frame * 6) / 80) % 6
        base[o] = UInt8(40 + bar * 35); base[o + 1] = UInt8(255 - bar * 40); base[o + 2] = UInt8(60 + (y * 190 / h)); base[o + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "FAILED \(String(describing: writer.error))")
exit(writer.status == .completed ? 0 : 1)
