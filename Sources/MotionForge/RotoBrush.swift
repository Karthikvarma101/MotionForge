import AVFoundation
import CoreImage
import MFRender
import Vision

/// Roto Brush: Apple's Vision finds the subject (or the people) in each frame of an image or video
/// layer, and its outline becomes a mask that follows it, one shape per frame. Works on the work
/// area (else the layer's whole span); the mask can then be inverted, feathered or corrected by
/// hand, which turns it into keyframes.
@MainActor
final class RotoBrush: ObservableObject {
    enum Subject: String, CaseIterable, Identifiable {
        case subject = "Main Subject"
        case people = "People"
        var id: String { rawValue }
    }

    @Published private(set) var progress: Double?  // while it runs
    @Published var message: String?
    private var cancelled = false

    func cancel() { cancelled = true }

    func run(model: EditorModel, layerID: UInt64, subject: Subject) async {
        guard progress == nil, let layer = model.layers.first(where: { $0.layerID == layerID }), layer.kind == .image,
              let asset = model.assets.first(where: { $0.assetID == layer.assetID }), !asset.missing else {
            message = "Roto Brush works on image and video layers."
            return
        }
        cancelled = false
        message = nil
        progress = 0
        defer { progress = nil }
        let comp = model.comp
        let size = CGSize(width: asset.width, height: asset.height)
        do {
            if !asset.isVideo {
                let url = URL(fileURLWithPath: asset.path)
                let outline = try await Task.detached {
                    guard let image = Self.loadImage(url) else { throw UpdateError("Can’t read \(url.lastPathComponent)") }
                    return try Self.outline(of: image, subject: subject, size: size)
                }.value
                guard let outline else { message = "No \(subject == .people ? "person" : "subject") found."; return }
                model.edit { _ = $0.addTrackedMask(layer: layerID, frames: [outline], start: 0, rate: comp.fps, name: "Roto Brush") }
                message = "Masked the \(subject == .people ? "people" : "subject")."
                return
            }
            // Footage: every frame of the work area inside the layer (or the layer's span).
            let start = max(layer.inPoint, comp.hasWorkArea ? comp.workAreaStart : 0, 0)
            let end = min(layer.outPoint, comp.hasWorkArea ? comp.workAreaEnd : comp.duration)
            let count = max(1, Int(((end - start) * comp.fps).rounded()))
            let times = (0..<count).map { i -> CMTime in
                let source = min(max(0, start + Double(i) / comp.fps - layer.startTime), max(0, asset.duration - 1 / max(asset.fps, 1)))
                return CMTime(seconds: source, preferredTimescale: 600_000)
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: asset.path)))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1280, height: 1280)  // outlines are found at this size, then scaled
            var outlines: [[MFPathVertex]] = []
            var found = 0
            var done = 0
            var unreadable = 0
            for await result in generator.images(for: times) {
                if cancelled { break }
                // A frame the grabber can't decode (it happens at a clip's edges) keeps the last outline.
                var outline: [MFPathVertex]?
                if let image = try? result.image {
                    outline = try await Task.detached { try Self.outline(of: image, subject: subject, size: size) }.value
                } else {
                    unreadable += 1
                }
                if let outline { found += 1 }
                // A frame without a subject keeps the last outline (or waits for the first one).
                outlines.append(outline ?? outlines.last ?? [])
                done += 1
                progress = Double(done) / Double(count)
            }
            if cancelled {
                message = "Roto Brush stopped."
                return
            }
            guard found > 0, let first = outlines.first(where: { !$0.isEmpty }) else {
                message = unreadable == count ? "The video frames couldn’t be read."
                    : "No \(subject == .people ? "person" : "subject") found in these frames."
                return
            }
            let frames = outlines.map { $0.isEmpty ? first : $0 }
            var id: UInt64 = 0
            model.edit { id = $0.addTrackedMask(layer: layerID, frames: frames, start: start, rate: comp.fps, name: "Roto Brush") }
            message = id != 0 ? "Roto Brush followed the \(subject == .people ? "people" : "subject") over \(frames.count) frames." : nil
        } catch {
            message = "Roto Brush failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func loadImage(_ url: URL) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) {
            return img
        }
        var rect = CGRect.zero  // SVG / PDF artwork
        return NSImage(contentsOf: url)?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The largest region's outline as a smooth closed path, in layer pixels (`size` = the layer's
    /// media size), or nil if there's nothing there.
    nonisolated static func outline(of image: CGImage, subject: Subject, size: CGSize) throws -> [MFPathVertex]? {
        let handler = VNImageRequestHandler(cgImage: image)
        let mask: CIImage
        switch subject {
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let o = request.results?.first, !o.allInstances.isEmpty else { return nil }
            mask = CIImage(cvPixelBuffer: try o.generateScaledMaskForImage(forInstances: o.allInstances, from: handler))
        case .people:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            guard let o = request.results?.first else { return nil }
            mask = CIImage(cvPixelBuffer: o.pixelBuffer)
        }
        let contours = VNDetectContoursRequest()
        contours.detectsDarkOnLight = false  // a light subject on black
        contours.contrastAdjustment = 1
        contours.maximumImageDimension = 512
        try VNImageRequestHandler(ciImage: mask).perform([contours])
        guard let all = contours.results?.first?.topLevelContours,
              let biggest = all.max(by: { area($0.normalizedPoints) < area($1.normalizedPoints) }),
              area(biggest.normalizedPoints) > 0.0005,
              let simple = try? biggest.polygonApproximation(epsilon: 0.0025), simple.pointCount >= 3 else { return nil }
        // Vision's points are 0–1 with the origin at the bottom left; layers are pixels, y down.
        let pts = simple.normalizedPoints.map { CGPoint(x: Double($0.x) * size.width, y: (1 - Double($0.y)) * size.height) }
        return smooth(pts)
    }

    /// Catmull-Rom handles: a soft curve through every point.
    nonisolated static func smooth(_ p: [CGPoint]) -> [MFPathVertex] {
        let n = p.count
        return (0..<n).map { i in
            let a = p[(i + n - 1) % n], b = p[(i + 1) % n]
            let t = CGPoint(x: (b.x - a.x) / 6, y: (b.y - a.y) / 6)
            return MFPathVertex(point: p[i], inTangent: CGPoint(x: -t.x, y: -t.y), outTangent: t)
        }
    }

    nonisolated static func area(_ pts: [SIMD2<Float>]) -> Double {
        guard pts.count > 2 else { return 0 }
        var s = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }
}
