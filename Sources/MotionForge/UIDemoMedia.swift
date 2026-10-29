import AppKit
import AVFoundation
import MFRender

/// Scripted check of footage and rotoscoping in the real app (scripts/ui-demo-media.sh): imports a
/// generated clip (a ball crossing the frame), a PNG and an SVG through the normal import, renders
/// frames, runs the Roto Brush on the clip, rotoscopes a mask by hand in the viewer and exports a
/// video. Renders, `media.json` and the export go to the output folder.
extension UIDemo {
    @MainActor static func runMedia(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String, _ detail: Any? = nil) {
                print("ui-demo-media \(ok ? "ok  " : "FAIL") \(what)\(detail.map { " (\($0))" } ?? "")")
                log.append(["check": what, "ok": ok, "detail": "\(detail ?? "")"])
                if !ok { failures.append(what) }
            }
            @MainActor func finish() -> Never {
                log.append(["failures": failures])
                if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted]) {
                    try? data.write(to: out.appendingPathComponent("media.json"))
                }
                print(failures.isEmpty ? "ui-demo-media: all checks passed" : "ui-demo-media: FAILED \(failures)")
                model.engine.markCleanForNewDocument()
                model.applicationWillTerminate()
                exit(failures.isEmpty ? 0 : 1)
            }
            @MainActor func render(_ name: String, _ t: Double) {
                try? model.engine.writePNG(atTime: t, scale: 1, transparent: false, toPath: out.appendingPathComponent("\(name).png").path)
            }
            @MainActor func pixel(_ t: Double, _ x: Int, _ y: Int) -> (Int, Int, Int) {
                guard let img = try? model.engine.copyImage(atTime: t, scale: 1, transparent: false) else { return (-1, -1, -1) }
                return sample(img, x, y)
            }
            try? await Task.sleep(for: .seconds(1))

            // Media made here: a 2 s clip of a ball crossing a light frame, a PNG of the ball, an SVG.
            let movie = out.appendingPathComponent("ball.mov")
            guard writeBallMovie(to: movie) else { check(false, "make the test clip"); finish() }
            let png = out.appendingPathComponent("ball.png")
            if let still = ballFrame(x: 320) {
                try? NSBitmapImageRep(cgImage: still).representation(using: .png, properties: [:])?.write(to: png)
            }
            let svg = out.appendingPathComponent("badge.svg")
            try? "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><rect rx='14' width='120' height='60' fill='#22aa66'/></svg>"
                .write(to: svg, atomically: true, encoding: .utf8)

            var comp: UInt64 = 0
            model.edit { comp = $0.addComposition(name: "Media Check", width: 640, height: 360, fps: 30, duration: 2) }
            model.openComposition(comp)
            model.importMedia(urls: [svg, png, movie], addToComposition: true)  // the clip ends up on top
            try? await Task.sleep(for: .seconds(1))
            let assets = model.assets
            let clipAsset = assets.first { $0.name == "ball.mov" }
            check(clipAsset?.isVideo == true && clipAsset?.width == 640 && clipAsset?.height == 360 && abs((clipAsset?.fps ?? 0) - 30) < 0.01,
                  "the clip imports as 640×360 30 fps footage", clipAsset.map { "\($0.width)×\($0.height) \($0.fps) fps \($0.duration) s" })
            check(assets.contains { $0.name == "ball.png" && !$0.isVideo && $0.width == 640 }, "the PNG imports as an image")
            check(assets.contains { $0.name == "badge.svg" && $0.width >= 1000 }, "the SVG imports (drawn at ~1000 px)")
            guard let clip = model.layers.first(where: { $0.isVideo }) else { check(false, "a footage layer"); finish() }
            check(model.layers.count == 3 && clip.icon == "film", "three layers, the clip as footage")

            // The ball is where each frame put it: x = 120 + 400·t/2.
            for t in [0.25, 1.0, 1.75] {
                let x = Int(120 + 400 * t / 2), (r, g, b) = pixel(t, x, 180)
                check(b > 150 && r < 90, "frame at \(t) s shows the ball at x \(x)", "\(r),\(g),\(b)")
            }
            render("media-01-clip-at-1s", 1)

            // Roto Brush on the clip: a mask that follows the ball.
            model.selectLayer(clip.layerID, mode: .replace)
            let started = Date()
            await model.roto.run(model: model, layerID: clip.layerID, subject: .subject)
            let rotoMask = model.layers.first { $0.layerID == clip.layerID }?.masks.first { $0.tracked }
            check(rotoMask != nil, "Roto Brush adds a tracked mask", "\(model.roto.message ?? "") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            if let m = rotoMask {
                func centre(_ t: Double) -> CGPoint {
                    let v = model.engine.maskPath(m.maskID, layer: clip.layerID, time: t)
                    let n = Double(max(1, v.count))
                    return CGPoint(x: v.map(\.point.x).reduce(0, +) / n, y: v.map(\.point.y).reduce(0, +) / n)
                }
                let a = centre(0.2), b = centre(1.8)
                check(abs(a.x - 160) < 25 && abs(b.x - 480) < 25 && abs(a.y - 180) < 25, "its outline follows the ball",
                      "x \(Int(a.x)) → \(Int(b.x))")
                // Outside the mask the clip is gone: the PNG below shows through at the left edge.
                render("media-02-roto-brush-at-1.5s", 1.5)
                let (r, g, bl) = pixel(1.5, 40, 40)
                check(abs(r - g) < 30 && abs(g - bl) < 30 && r > 150, "outside the mask the layers below show", "\(r),\(g),\(bl)")
            }

            // Rotoscoping by hand: animate a mask on the PNG layer and move a corner at 1 s in the viewer.
            if let still = model.layers.first(where: { $0.name == "ball.png" }) {
                model.selectLayer(still.layerID, mode: .replace)
                model.addMask(.rectangle)
                if let m = model.layers.first(where: { $0.layerID == still.layerID })?.masks.first {
                    model.time.time = 0
                    model.edit { _ = $0.setMaskPathAnimated(m.maskID, layer: still.layerID, animated: true, time: 0) }
                    model.time.time = 1
                    model.tool = .select
                    try? await Task.sleep(for: .seconds(0.5))
                    if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                       let viewer = findViewerMedia(in: window.contentView) {
                        let corner = model.engine.maskPath(m.maskID, layer: still.layerID, time: 1).first?.point ?? .zero
                        let g = model.viewerGeometry(viewer.bounds.size)
                        let a = g.toView(model.engine.layerToComp(corner, layer: still.layerID, time: 1))
                        let b = CGPoint(x: a.x + 40 * g.scale, y: a.y + 30 * g.scale)
                        func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                            NSEvent.mouseEvent(with: type, location: viewer.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        }
                        viewer.mouseDown(with: ev(.leftMouseDown, a))
                        for i in 1...8 { viewer.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * Double(i) / 8, y: a.y + (b.y - a.y) * Double(i) / 8))) }
                        viewer.mouseUp(with: ev(.leftMouseUp, b))
                    }
                    let after = model.layers.first(where: { $0.layerID == still.layerID })?.masks.first
                    let moved = model.engine.maskPath(m.maskID, layer: still.layerID, time: 1).first?.point ?? .zero
                    let before = model.engine.maskPath(m.maskID, layer: still.layerID, time: 0).first?.point ?? .zero
                    check(after?.pathKeyTimes.count == 2 && abs(moved.x - before.x - 40) < 2 && abs(moved.y - before.y - 30) < 2,
                          "dragging a mask point at 1 s adds a key there", "\(after?.pathKeyTimes ?? [])")
                    let halfway = model.engine.maskPath(m.maskID, layer: still.layerID, time: 0.5).first?.point ?? .zero
                    check(abs(halfway.x - before.x - 20) < 2, "between keys the outline morphs", "x +\(Int(halfway.x - before.x))")
                }
            }

            // Export: the footage is in the video (frames decoded exactly, not stand-ins).
            let exportURL = out.appendingPathComponent("export.mp4")
            let settings = MFExportSettings()
            settings.format = .h264
            settings.scale = 1
            model.layers.filter { $0.name == "ball.png" }.forEach { l in model.edit { _ = $0.setLayer(l.layerID, visible: false) } }
            model.edit { e in for m in model.layers.first(where: { $0.isVideo })?.masks ?? [] { _ = e.setMask(m.maskID, layer: clip.layerID, enabled: false) } }
            model.startExport(settings, to: exportURL, summary: "check")
            for _ in 0..<600 where model.exporter != nil { try? await Task.sleep(for: .seconds(0.1)) }
            check(model.exportStatus?.finished == true && model.exportStatus?.error == nil, "the export finishes", model.exportStatus?.error)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            if let img = try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image {
                let (r, _, b) = sample(img, 420, 180)  // x = 120 + 400·1.5/2
                check(b > 150 && r < 90, "the exported video shows the ball where the clip has it")
            } else {
                check(false, "the exported video can be read")
            }
            finish()
        }
    }

    /// One frame of the test clip: a blue ball at `x` (y 180, radius 60) on light grey, 640×360.
    nonisolated static func ballFrame(x: Double) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.86, blue: 0.84, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.25, blue: 0.85, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x - 60, y: 180 - 60, width: 120, height: 120))
        return ctx.makeImage()
    }

    /// 2 s at 30 fps, H.264: the ball moves from x 120 to x 520.
    nonisolated static func writeBallMovie(to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640,
                                                                           AVVideoHeightKey: 360])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool, let frame = ballFrame(x: 120 + 400 * Double(i) / 60) else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 640, height: 360, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(frame, in: CGRect(x: 0, y: 0, width: 640, height: 360))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    /// sRGB 0–255 at (x, y) from the top left.
    nonisolated static func sample(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (-1, -1, -1) }
        let w = Double(img.width), h = Double(img.height)
        ctx.draw(img, in: CGRect(x: -Double(x), y: -(h - Double(y) - 1), width: w, height: h))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    @MainActor private static func findViewerMedia(in view: NSView?) -> ViewerMTKView? {
        guard let view else { return nil }
        if let v = view as? ViewerMTKView { return v }
        for sub in view.subviews { if let v = findViewerMedia(in: sub) { return v } }
        return nil
    }
}
