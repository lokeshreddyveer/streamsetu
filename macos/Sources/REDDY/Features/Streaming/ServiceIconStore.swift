import AppKit

/// The official icons of the services, bundled with the app and decoded once at launch so the Services list opens with them already in place
/// (no network, works offline). A service without a bundled icon returns nil and the list shows its letter tile.
@MainActor
enum ServiceIconStore {
    private static var cache: [String: NSImage] = [:]
    private static var started = false

    /// Decodes every bundled icon off the main thread, once. Safe to call again.
    static func preload() {
        guard !started else { return }
        started = true
        let ids = ProviderID.allCases.map(\.rawValue)
        Task.detached(priority: .utility) {
            var loaded: [String: NSImage] = [:]
            for id in ids { if let image = decode(id) { loaded[id] = image } }
            await MainActor.run { for (id, image) in loaded { cache[id] = image } }
        }
    }

    /// Synchronous, from memory. Falls back to a direct read when the preload has not finished.
    static func icon(for id: ProviderID) -> NSImage? {
        if let image = cache[id.rawValue] { return image }
        guard let image = decode(id.rawValue) else { return nil }
        cache[id.rawValue] = image
        return image
    }

    /// Test hook: waits until the preload has filled the cache.
    static func preloadAndWait() async {
        for id in ProviderID.allCases { if cache[id.rawValue] == nil, let image = decode(id.rawValue) { cache[id.rawValue] = image } }
    }

    nonisolated static func url(_ id: String) -> URL? {
        if let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "ServiceIcons") { return url }
        #if DEBUG
        // swift run and swift test have no app bundle, so the file is read from the package's Resources folder.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = packageRoot.appendingPathComponent("Resources/ServiceIcons/\(id).png")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
        #else
        return nil
        #endif
    }

    nonisolated private static func decode(_ id: String) -> NSImage? { url(id).flatMap { NSImage(contentsOf: $0) }.map(normalized) }

    /// Side, in pixels, of every normalised icon (the sources are 256 px; smaller ones are resampled once, here, never again at draw time).
    nonisolated static let normalizedSide = 256

    /// The ONE place artwork is made uniform: trims fully transparent margins to the opaque bounding box, centre-crops it to a square, fills any
    /// still-transparent pixel (the corners of a rounded-corner icon) with the icon's own dominant edge colour, and resamples once to
    /// `normalizedSide` square. The result is fully opaque, so the shared rounded-square mask never shows a gap. Returns the input on failure.
    nonisolated static func normalized(_ image: NSImage) -> NSImage {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return image }
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return image }
        // bounding box of pixels that are not (nearly) transparent; row 0 of the buffer is the top row
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 16 {
            if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y }
        } }
        guard maxX >= minX, maxY >= minY else { return image }
        let bw = maxX - minX + 1, bh = maxY - minY + 1, side = min(bw, bh)
        let cx = minX + (bw - side) / 2, cy = minY + (bh - side) / 2
        // dominant edge colour: mean of the opaque pixels in the outer 3 px ring of the square (premultiplied, so opaque ones only)
        var r = 0, g = 0, b = 0, n = 0
        for y in cy..<(cy + side) { for x in cx..<(cx + side) {
            let edge = x < cx + 3 || x >= cx + side - 3 || y < cy + 3 || y >= cy + side - 3
            let i = (y * w + x) * 4
            if edge && px[i + 3] > 240 { r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2]); n += 1 }
        } }
        let fill: CGColor = n > 0 ? CGColor(srgbRed: CGFloat(r) / CGFloat(n) / 255, green: CGFloat(g) / CGFloat(n) / 255, blue: CGFloat(b) / CGFloat(n) / 255, alpha: 1)
                                  : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        guard let crop = cg.cropping(to: CGRect(x: cx, y: cy, width: side, height: side)) else { return image }       // cropping uses top-left origin
        let out = normalizedSide
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return image }
        ctx.setFillColor(fill); ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let result = ctx.makeImage() else { return image }
        return NSImage(cgImage: result, size: NSSize(width: out, height: out))
    }
}
