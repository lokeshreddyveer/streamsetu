import Foundation
import CoreGraphics

// The maths of the light around a music video, kept free of views and players so it is tested with plain numbers.
// Plan: take a tiny copy of the current frame, sample it on a coarse grid that covers the whole glow area (inside the picture the frame itself, outside the
// frame's edge band on the line toward the picture's centre), blur the grid a little, ease it toward the previous grid, and let the glow fade out with distance.

struct MusicAmbientFrame: Sendable, Equatable {
    var width: Int, height: Int
    /// Tightly packed RGBA, 8 bits per channel.
    var rgba: [UInt8]

    func color(x: Double, y: Double) -> SIMD3<Float> {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return .zero }
        let px = min(width - 1, max(0, Int((x * Double(width)).rounded(.down))))
        let py = min(height - 1, max(0, Int((y * Double(height)).rounded(.down))))
        let i = (py * width + px) * 4
        return SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255
    }
}

enum MusicAmbientMath {
    /// At most this many redraws a second; the smoothing hides the gaps.
    static let framesPerSecond = 15.0
    static let columns = 32, rows = 18
    static let blurSigmaCells = 1.5
    static let smoothingTime = 0.12
    /// The glow reaches this fraction of the picture's height beyond the picture.
    static let reachFraction = 0.3
    /// Outside samples are pulled this far in from the edge toward the centre so they read the edge band, not the edge row.
    static let edgePull = 0.12

    /// An 11 tap gaussian whose weights add up to exactly 1.
    static func kernel(sigma: Double, taps: Int = 11) -> [Double] {
        let r = taps / 2
        let raw = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }

    /// Where a cell's colour is read from the frame, in frame coordinates 0...1. `cell` and `picture` are in the glow area's unit square.
    static func sourcePoint(cell: CGPoint, picture: CGRect) -> CGPoint {
        guard picture.width > 0, picture.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let rx = (cell.x - picture.minX) / picture.width, ry = (cell.y - picture.minY) / picture.height
        if rx >= 0, rx <= 1, ry >= 0, ry <= 1 { return CGPoint(x: rx, y: ry) }
        // Toward the centre of the picture from the cell: land on the edge, then step in by edgePull of the half size.
        let dx = rx - 0.5, dy = ry - 0.5
        let scale = 0.5 / max(abs(dx), abs(dy))
        let k = 1 - edgePull
        return CGPoint(x: min(1, max(0, 0.5 + dx * scale * k)), y: min(1, max(0, 0.5 + dy * scale * k)))
    }

    /// Sample every cell of the grid. Row-major, `columns` x `rows`.
    static func sample(_ frame: MusicAmbientFrame, picture: CGRect, columns c: Int = columns, rows r: Int = rows) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(c * r)
        for j in 0..<r {
            for i in 0..<c {
                let p = sourcePoint(cell: CGPoint(x: (Double(i) + 0.5) / Double(c), y: (Double(j) + 0.5) / Double(r)), picture: picture)
                out.append(frame.color(x: p.x, y: p.y))
            }
        }
        return out
    }

    /// Separable blur with edges held.
    static func blur(_ grid: [SIMD3<Float>], columns c: Int, rows r: Int, sigma: Double = blurSigmaCells) -> [SIMD3<Float>] {
        guard grid.count == c * r, c > 0, r > 0 else { return grid }
        let k = kernel(sigma: sigma).map { Float($0) }, h = k.count / 2
        var tmp = grid, out = grid
        for j in 0..<r { for i in 0..<c {
            var acc = SIMD3<Float>.zero
            for t in -h...h { acc += grid[j * c + min(c - 1, max(0, i + t))] * k[t + h] }
            tmp[j * c + i] = acc
        } }
        for j in 0..<r { for i in 0..<c {
            var acc = SIMD3<Float>.zero
            for t in -h...h { acc += tmp[min(r - 1, max(0, j + t)) * c + i] * k[t + h] }
            out[j * c + i] = acc
        } }
        return out
    }

    /// Eases the shown grid toward the new one. A first frame (no previous) snaps. Time constant 0.12 s, so a cut is 95% there in about 0.35 s.
    static func smooth(previous: [SIMD3<Float>]?, new: [SIMD3<Float>], dt: Double, tau: Double = smoothingTime) -> [SIMD3<Float>] {
        guard let previous, previous.count == new.count, dt > 0 else { return new }
        let a = Float(1 - exp(-dt / tau))
        return zip(previous, new).map { $0 + ($1 - $0) * a }
    }

    static func smoothstep(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    /// Glow strength at a cell: 0 inside the picture (the video covers it), then fading to nothing over `reach` picture heights beyond it, squared.
    static func strength(cell: CGPoint, picture: CGRect, aspect: Double) -> Double {
        guard picture.height > 0 else { return 0 }
        // Distances are measured in picture heights, so x is scaled by the view's aspect (width / height) to stay isotropic.
        let dx = max(picture.minX - cell.x, 0, cell.x - picture.maxX) * aspect
        let dy = max(picture.minY - cell.y, 0, cell.y - picture.maxY)
        let d = (dx * dx + dy * dy).squareRoot() / (picture.height * 1.0)
        if d <= 0 { return 0 }
        let f = 1 - smoothstep(d / reachFraction)
        return f * f
    }

    /// RGBA bytes of a grid with the glow strength as alpha (premultiplied), ready for an image.
    static func pixels(_ grid: [SIMD3<Float>], columns c: Int, rows r: Int, picture: CGRect, aspect: Double) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: c * r * 4)
        for j in 0..<r { for i in 0..<c {
            let a = Float(strength(cell: CGPoint(x: (Double(i) + 0.5) / Double(c), y: (Double(j) + 0.5) / Double(r)), picture: picture, aspect: aspect))
            let col = grid[j * c + i]
            let o = (j * c + i) * 4
            for k in 0..<3 { out[o + k] = UInt8(min(255, max(0, col[k] * a * 255))) }
            out[o + 3] = UInt8(min(255, max(0, a * 255)))
        } }
        return out
    }

    /// The same grid from a single colour (the cover's dominant one, brightest at the middle): used while no video frame exists.
    static func flat(_ color: SIMD3<Float>, columns c: Int = columns, rows r: Int = rows) -> [SIMD3<Float>] { [SIMD3<Float>](repeating: color, count: c * r) }

    /// Downsamples an RGBA image to a frame of at most `side` pixels wide by point sampling, for covers.
    static func frame(fromRGBA rgba: [UInt8], width: Int, height: Int, maxWidth: Int = 64) -> MusicAmbientFrame {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return MusicAmbientFrame(width: 0, height: 0, rgba: []) }
        let w = min(width, maxWidth), h = max(1, height * w / width)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let sx = min(width - 1, x * width / w), sy = min(height - 1, y * height / h)
            let s = (sy * width + sx) * 4, d = (y * w + x) * 4
            out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]
        } }
        return MusicAmbientFrame(width: w, height: h, rgba: out)
    }
}
