// Draws the disk-image window background for scripts/make-dmg.sh: an amber arrow from the app to
// Applications and two lines of help. Finder puts a background picture on white and labels the icons in
// black in both light and dark mode, so the canvas is left transparent and the text is dark.
// Everything sits in the top 330 pt: Finder's path and status bars, if the viewer has them on, cover the
// bottom of the window.
//   swift scripts/make-dmg-background.swift <out-dir>   # background.png (600 × 400) + background@2x.png
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = CGSize(width: 600, height: 400)
// Icon centres in Finder's top-left coordinates; scripts/dmg-settings.py places the icons here.
let appCentre = CGPoint(x: 150, y: 160), applicationsCentre = CGPoint(x: 450, y: 160)
let iconSize: CGFloat = 128

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func draw(in cg: CGContext) {
    // Flip to top-left coordinates so the numbers match Finder's.
    cg.translateBy(x: 0, y: canvas.height)
    cg.scaleBy(x: 1, y: -1)

    let y = appCentre.y
    let x0 = appCentre.x + iconSize / 2 + 26, x1 = applicationsCentre.x - iconSize / 2 - 26
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: x0, y: y))
    arrow.addLine(to: CGPoint(x: x1, y: y))
    arrow.move(to: CGPoint(x: x1 - 13, y: y - 13))
    arrow.addLine(to: CGPoint(x: x1, y: y))
    arrow.addLine(to: CGPoint(x: x1 - 13, y: y + 13))
    let stroke = arrow.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0xf2994a).cgColor, srgb(0xf8d06b).cgColor] as CFArray,
                              locations: [0, 1])!
    cg.saveGState()
    cg.addPath(stroke)
    cg.clip()
    cg.drawLinearGradient(gradient, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
    cg.restoreGState()

    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    func line(_ text: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: colour, .paragraphStyle: centred]
        NSAttributedString(string: text, attributes: attrs)
            .draw(in: CGRect(x: 0, y: top, width: canvas.width, height: size * 1.6))
    }
    line("Drag MotionForge into Applications", size: 14, weight: .semibold, colour: srgb(0x48484a), top: 280)
    line("First launch blocked? System Settings › Privacy & Security › Open Anyway",
         size: 11, weight: .regular, colour: srgb(0x6e6e73), top: 306)
}

func render(scale: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale,
                               pixelsHigh: Int(canvas.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas  // 72 or 144 dpi, which is how Finder pairs the two sizes; drawing is in points
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

try render(scale: 1, name: "background.png")
try render(scale: 2, name: "background@2x.png")
