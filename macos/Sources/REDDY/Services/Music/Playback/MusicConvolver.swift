import Foundation
import Accelerate

// Real-time partitioned FFT convolution on Accelerate. Two levels: the first stretch of the response is cut into small partitions that
// run every hop, the rest into big ones that run rarely, so a ten-second room costs little. Everything is allocated up front; `process`
// never allocates, locks or throws, so it can run on the audio thread.

/// One channel of convolution. The response is advanced by one hop (its leading silence pays for it), so the wet signal is exactly in time
/// with the dry one when the response starts at least one hop late, which every room does.
final class MusicChannelConvolver: @unchecked Sendable {
    /// Samples per head hop. 256 is 5.8 ms at 44.1 kHz; the shortest first reflection of any room is 6 ms.
    static let hop = 256
    static let headPartitions = 16
    /// The tail runs on blocks of this size; `headPartitions * hop` must be a multiple of it.
    static let tailHop = 2048

    private let A = MusicChannelConvolver.hop
    private let NA = MusicChannelConvolver.headPartitions
    private let C = MusicChannelConvolver.tailHop
    private let hopsPerTail: Int
    /// Frames the response was advanced by (at most one hop). The wet signal is late by `hop - advance` frames when the response starts earlier.
    let advance: Int
    private let tailPartitions: Int
    private let tailDelayBlocks: Int

    private let setupA: FFTSetup, setupC: FFTSetup
    private let log2A: vDSP_Length, log2C: vDSP_Length

    // Spectra, split complex, packed (bin 0 holds DC in real and Nyquist in imag).
    private let headH: UnsafeMutablePointer<Float>      // NA * 2 * A floats: real then imag, A each
    private let headFDL: UnsafeMutablePointer<Float>
    private let tailH: UnsafeMutablePointer<Float>?
    private let tailFDL: UnsafeMutablePointer<Float>?
    private let accA: UnsafeMutablePointer<Float>
    private let accC: UnsafeMutablePointer<Float>
    private let winA: UnsafeMutablePointer<Float>       // 2A time samples
    private let winC: UnsafeMutablePointer<Float>       // 2C time samples
    private let scratchA: UnsafeMutablePointer<Float>   // 2A, for the inverse
    private let scratchC: UnsafeMutablePointer<Float>
    private let hopIn: UnsafeMutablePointer<Float>
    private let ready: UnsafeMutablePointer<Float>
    private let tailOut: UnsafeMutablePointer<Float>    // 3 blocks of C

    private var fill = 0
    private var headIndex = 0
    private var tailIndex = 0
    private var hopCounter = 0       // hops since the start, wraps with the tail ring
    private var tailCounter = 0
    private var frameClock = 0       // frames consumed, mod 3C, to find the tail ring offset
    private let scaleA: Float, scaleC: Float

    init(ir: [Float]) {
        let A = MusicChannelConvolver.hop, NA = MusicChannelConvolver.headPartitions, C = MusicChannelConvolver.tailHop
        hopsPerTail = C / A
        let lead = min(A, ir.firstIndex { $0 != 0 } ?? 0)
        advance = lead
        // The advanced response: drop the leading `lead` frames.
        let h = lead < ir.count ? Array(ir[lead...]) : [0]
        let headEnd = NA * A
        let tailLen = max(0, h.count - headEnd)
        let tailParts = (tailLen + C - 1) / C
        tailPartitions = tailParts
        tailDelayBlocks = headEnd / C
        log2A = vDSP_Length(log2(Double(2 * A)).rounded())
        log2C = vDSP_Length(log2(Double(2 * C)).rounded())
        setupA = vDSP_create_fftsetup(log2A, FFTRadix(kFFTRadix2))!
        setupC = vDSP_create_fftsetup(log2C, FFTRadix(kFFTRadix2))!
        // Forward gives twice the DFT and the unnormalised inverse N times the signal; one factor of that product is folded into the response.
        scaleA = 1 / Float(4 * 2 * A)
        scaleC = 1 / Float(4 * 2 * C)

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n))
            p.initialize(repeating: 0, count: max(1, n))
            return p
        }
        headH = alloc(NA * 2 * A); headFDL = alloc(NA * 2 * A)
        accA = alloc(2 * A); accC = alloc(2 * C)
        winA = alloc(2 * A); winC = alloc(2 * C)
        scratchA = alloc(2 * A); scratchC = alloc(2 * C)
        hopIn = alloc(A); ready = alloc(A); tailOut = alloc(3 * C)
        if tailParts > 0 { tailH = alloc(tailParts * 2 * C); tailFDL = alloc(tailParts * 2 * C) } else { tailH = nil; tailFDL = nil }

        // Spectra of the response partitions.
        h.withUnsafeBufferPointer { src in
            for p in 0..<NA {
                let from = p * A
                guard from < src.count else { break }
                let n = min(A, src.count - from)
                let spectrum = headH + p * 2 * A
                for i in 0..<(2 * A) { scratchA[i] = 0 }
                for i in 0..<n { scratchA[i] = src[from + i] }
                forward(scratchA, spectrum, setup: setupA, log2n: log2A, n: 2 * A)
                var s = scaleA
                vDSP_vsmul(spectrum, 1, &s, spectrum, 1, vDSP_Length(2 * A))
            }
            if let tailH {
                for q in 0..<tailParts {
                    let from = headEnd + q * C
                    let n = min(C, src.count - from)
                    let spectrum = tailH + q * 2 * C
                    for i in 0..<(2 * C) { scratchC[i] = 0 }
                    for i in 0..<max(0, n) { scratchC[i] = src[from + i] }
                    forward(scratchC, spectrum, setup: setupC, log2n: log2C, n: 2 * C)
                    var s = scaleC
                    vDSP_vsmul(spectrum, 1, &s, spectrum, 1, vDSP_Length(2 * C))
                }
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setupA); vDSP_destroy_fftsetup(setupC)
        for p in [headH, headFDL, accA, accC, winA, winC, scratchA, scratchC, hopIn, ready, tailOut] { p.deallocate() }
        tailH?.deallocate(); tailFDL?.deallocate()
    }

    /// Forgets everything heard so far, so the tail of the previous song does not carry into the next.
    func clear() {
        let A = self.A, C = self.C, NA = self.NA
        headFDL.update(repeating: 0, count: NA * 2 * A)
        if let t = tailFDL { t.update(repeating: 0, count: tailPartitions * 2 * C) }
        winA.update(repeating: 0, count: 2 * A); winC.update(repeating: 0, count: 2 * C)
        hopIn.update(repeating: 0, count: A); ready.update(repeating: 0, count: A)
        tailOut.update(repeating: 0, count: 3 * C)
        fill = 0; headIndex = 0; tailIndex = 0; hopCounter = 0; tailCounter = 0; frameClock = 0
    }

    /// Wet output for `n` input frames. Safe on the audio thread.
    func process(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>, frames n: Int) {
        var done = 0
        while done < n {
            let take = min(n - done, A - fill)
            for i in 0..<take {
                hopIn[fill + i] = x[done + i]
                y[done + i] = ready[fill + i]
            }
            fill += take; done += take
            if fill == A { runHop(); fill = 0 }
        }
    }

    // MARK: one hop

    private func runHop() {
        let A = self.A, C = self.C
        // Head: slide the window, transform, store, multiply-accumulate every partition.
        for i in 0..<A { winA[i] = winA[A + i] }
        for i in 0..<A { winA[A + i] = hopIn[i] }
        let slot = headFDL + headIndex * 2 * A
        forward(winA, slot, setup: setupA, log2n: log2A, n: 2 * A)
        accumulate(fdl: headFDL, h: headH, count: NA, newest: headIndex, bins: A, acc: accA)
        inverse(accA, scratchA, setup: setupA, log2n: log2A, n: 2 * A)
        // Overlap-save: the second half is the valid one.
        let ringOffset = frameClock % (3 * C)
        for i in 0..<A { ready[i] = scratchA[A + i] + tailOut[(ringOffset + i) % (3 * C)] }
        headIndex = (headIndex + 1) % NA
        frameClock += A

        // Tail: collect a block, and when it is complete work out the block that will be needed `tailDelayBlocks` blocks later.
        if tailPartitions > 0 {
            for i in 0..<A { winC[C + tailCounter * A + i] = hopIn[i] }
            tailCounter += 1
            if tailCounter == hopsPerTail {
                tailCounter = 0
                runTail()
            }
        }
    }

    private func runTail() {
        guard let tailFDL, let tailH else { return }
        let C = self.C
        let slot = tailFDL + tailIndex * 2 * C
        forward(winC, slot, setup: setupC, log2n: log2C, n: 2 * C)
        accumulate(fdl: tailFDL, h: tailH, count: tailPartitions, newest: tailIndex, bins: C, acc: accC)
        inverse(accC, scratchC, setup: setupC, log2n: log2C, n: 2 * C)
        // Block that this result belongs to: the one `tailDelayBlocks` after the block just completed.
        let completed = (frameClock / C) - 1    // index of the block that just finished
        let target = (completed + tailDelayBlocks) % 3
        let dst = tailOut + target * C
        for i in 0..<C { dst[i] = scratchC[C + i] }
        tailIndex = (tailIndex + 1) % tailPartitions
        // Slide: the finished block becomes the first half of the next window.
        for i in 0..<C { winC[i] = winC[C + i] }
    }

    // MARK: Accelerate helpers

    /// Real FFT of `n` time samples into packed split complex stored as [real(n/2) | imag(n/2)].
    private func forward(_ time: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, setup: FFTSetup, log2n: vDSP_Length, n: Int) {
        var split = DSPSplitComplex(realp: out, imagp: out + n / 2)
        time.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    private func inverse(_ spectrum: UnsafeMutablePointer<Float>, _ time: UnsafeMutablePointer<Float>, setup: FFTSetup, log2n: vDSP_Length, n: Int) {
        var split = DSPSplitComplex(realp: spectrum, imagp: spectrum + n / 2)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        time.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2)) }
    }

    /// acc = sum over p of FDL[newest - p] * H[p], bin by bin.
    private func accumulate(fdl: UnsafeMutablePointer<Float>, h: UnsafeMutablePointer<Float>, count: Int, newest: Int, bins: Int,
                            acc: UnsafeMutablePointer<Float>) {
        acc.update(repeating: 0, count: 2 * bins)
        var dcRe: Float = 0, nyq: Float = 0
        var outIn = DSPSplitComplex(realp: acc + 1, imagp: acc + bins + 1)
        var outOut = outIn
        for p in 0..<count {
            var idx = newest - p
            if idx < 0 { idx += count }
            let x = fdl + idx * 2 * bins
            let hh = h + p * 2 * bins
            dcRe += x[0] * hh[0]
            nyq += x[bins] * hh[bins]
            var xs = DSPSplitComplex(realp: x + 1, imagp: x + bins + 1)
            var hs = DSPSplitComplex(realp: hh + 1, imagp: hh + bins + 1)
            vDSP_zvma(&xs, 1, &hs, 1, &outIn, 1, &outOut, 1, vDSP_Length(bins - 1))
        }
        acc[0] = dcRe
        acc[bins] = nyq
    }
}
