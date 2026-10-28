// Builds the macOS app icon from the brand artwork (Resources/Brand/MotionForge-AppIcon-source.png).
//
// The source is the glowing tile on a black square. The tile (measured: x 184–1072, y 161–1037,
// corner radius ≈ 207 px) is cut out with a matching rounded clip, so the outside becomes
// transparent, and placed on Apple's 1024 px icon grid (824 px tile, soft shadow). All sizes are
// written to an .iconset for `iconutil`.
//   swift scripts/make-icon.swift <source.png> <out.iconset> <master-1024.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("usage: make-icon.swift <source.png> <out.iconset> <master.png>")
    exit(1)
}
let srcTile = CGRect(x: 184, y: 161, width: 888, height: 876)  // top-left origin
let srcRadius = 207.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let k = Double(size) / 1024.0
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let radius = srcRadius * (824.0 / 888.0) * k
    let shape = CGPath(roundedRect: tile.insetBy(dx: 0.5 * k, dy: 0.5 * k), cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft shadow under the tile (CG's origin is bottom-left, so a negative y offset falls downward).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // The artwork, scaled so its tile lands exactly on `tile`, clipped to the rounded shape.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let sx = tile.width / srcTile.width, sy = tile.height / srcTile.height
    let artRect = CGRect(x: tile.minX - srcTile.minX * sx,
                         y: tile.minY - (Double(art.height) - srcTile.maxY) * sy,  // flip the top-left measurement
                         width: Double(art.width) * sx, height: Double(art.height) * sy)
    ctx.draw(art, in: artRect)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

try? FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(size: base), "\(args[2])/icon_\(base)x\(base).png")
    write(render(size: base * 2), "\(args[2])/icon_\(base)x\(base)@2x.png")
}
write(render(size: 1024), args[3])
print("wrote \(args[2]) and \(args[3])")
