import AppKit
// Builds the iOS app icon: the Mac icon is a rounded tile with transparent padding; iOS wants a full-bleed, opaque 1024 square
// (the system applies its own corner mask). Usage: make-ios-icon <mac-icon-1024.png> <out.png>
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("usage: make-ios-icon in.png out.png"); exit(1) }
let size = 1024, margin = Int(Double(cg.width) * 0.07 + 1)
let crop = CGRect(x: margin, y: margin, width: cg.width - 2 * margin, height: cg.height - 2 * margin)
guard let tile = cg.cropping(to: crop) else { exit(1) }
let rep = NSBitmapImageRep(cgImage: tile)
let sample = rep.colorAt(x: tile.width / 12, y: tile.height / 2) ?? NSColor(red: 0.02, green: 0.07, blue: 0.25, alpha: 1)   // dark navy well inside the tile
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor((sample.usingColorSpace(.deviceRGB) ?? sample).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.interpolationQuality = .high
ctx.draw(tile, in: CGRect(x: 0, y: 0, width: size, height: size))
let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote", args[2], "background", sample)
