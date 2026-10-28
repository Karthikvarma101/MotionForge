import Accelerate
import AVFoundation
import MFRender
import SwiftUI

/// Plays the active composition's audio layers in step with the viewer. The mix is rebuilt in the
/// background whenever what you'd hear changes; while it plays, the viewer takes its playhead from the
/// audio clock so picture and sound stay together.
@MainActor
final class AudioPlayback {
    private enum State { case idle, starting, playing }

    private let player = AVPlayer()
    private var clips: [MFAudioClipInfo] = []
    private var buildTask: Task<Void, Never>?
    private var mixDuration = 0.0
    private var state = State.idle
    private var wantsPlay = false
    private var startTime = 0.0
    private var startRequested = 0.0
    /// Where the playhead is (to carry on after the mix is rebuilt during playback).
    var playhead: () -> Double = { 0 }
    /// Failure to read one of the files, if any.
    private(set) var problem: String?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
    }

    var isAudible: Bool { mixDuration > 0 }

    /// Call after every document change; rebuilds the mix only when the clips changed.
    func update(clips new: [MFAudioClipInfo]) {
        guard new != clips else { return }
        clips = new
        buildTask?.cancel()
        if new.isEmpty {
            install(nil)
            problem = nil
            return
        }
        buildTask = Task.detached(priority: .userInitiated) { [new] in
            var error: NSError?
            let mix = MFAudioMix.make(clips: new, origin: 0, error: &error)
            let problem = error?.localizedDescription
            await MainActor.run { [weak self] in
                guard let self, self.clips == new else { return }
                self.install(mix)
                self.problem = problem
            }
        }
    }

    private func install(_ mix: MFAudioMix?) {
        let playing = wantsPlay
        player.pause()
        state = .idle
        if let mix {
            let item = AVPlayerItem(asset: mix.composition)
            item.audioMix = mix.audioMix
            player.replaceCurrentItem(with: item)
            mixDuration = mix.composition.duration.seconds
        } else {
            player.replaceCurrentItem(with: nil)
            mixDuration = 0
        }
        if playing { play(from: playhead()) }
    }

    func play(from t: Double) {
        player.pause()
        wantsPlay = true
        startTime = t
        state = .idle
        guard mixDuration > 0, t < mixDuration - 0.02 else { return }  // nothing to hear from here on
        state = .starting
        startRequested = CACurrentMediaTime()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            MainActor.assumeIsolated {
                guard done, let self, self.wantsPlay, self.state == .starting else { return }
                self.player.play()
            }
        }
    }

    func stop() {
        wantsPlay = false
        state = .idle
        player.pause()
    }

    /// The playhead while sound is coming out; the start time while it is starting up (hold the picture
    /// there); nil when nothing is playing (the viewer keeps its own clock).
    var clockTime: Double? {
        switch state {
        case .idle:
            return nil
        case .starting:
            if player.timeControlStatus == .playing {
                state = .playing
                return currentTime
            }
            if CACurrentMediaTime() - startRequested > 0.5 {  // don't hold the picture for long
                state = .idle
                return nil
            }
            return startTime
        case .playing:
            guard player.timeControlStatus == .playing else {  // reached the end of the sound
                state = .idle
                return nil
            }
            return currentTime
        }
    }

    private var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : startTime
    }
}

/// Peak envelopes of audio files for the timeline, computed once per file in the background.
@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()
    nonisolated static let peaksPerSecond = 100.0

    @Published private(set) var peaks: [String: [Float]] = [:]
    private var loading: Set<String> = []

    /// nil while the file is still being read.
    func peaks(for path: String) -> [Float]? {
        if let p = peaks[path] { return p }
        if loading.insert(path).inserted {
            Task.detached(priority: .utility) {
                let p = Self.read(path) ?? []
                await MainActor.run { WaveformStore.shared.peaks[path] = p }
            }
        }
        return nil
    }

    /// Largest absolute sample over all channels per 1/100 s.
    nonisolated static func read(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let format = file.processingFormat
        let per = max(1, Int(format.sampleRate / peaksPerSecond))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(per * 1024)) else { return nil }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / Double(per)) + 1)
        var bucket: Float = 0, filled = 0
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            var i = 0
            while i < n {
                let take = min(per - filled, n - i)
                for c in 0..<Int(format.channelCount) {
                    var m: Float = 0
                    vDSP_maxmgv(data[c] + i, 1, &m, vDSP_Length(take))
                    bucket = max(bucket, m)
                }
                filled += take
                i += take
                if filled == per {
                    out.append(bucket)
                    bucket = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { out.append(bucket) }
        return out
    }
}

/// The waveform inside an audio layer's bar: the file's peaks under the visible part of the layer.
struct WaveformView: View {
    @ObservedObject var store = WaveformStore.shared
    let path: String
    let startTime: Double   // where the file's time 0 sits on the timeline
    let mapper: TimeMapper
    let x0: CGFloat, x1: CGFloat

    var body: some View {
        let peaks = store.peaks(for: path) ?? []
        Canvas { ctx, size in
            guard !peaks.isEmpty, x1 > x0 else { return }
            let mid = size.height / 2, half = size.height / 2 - 1
            let secondsPerPixel = 1 / Double(mapper.pxPerSecond)
            var path = Path()
            var x = x0
            while x < x1 {
                let t = mapper.t(x) - startTime
                let a = Int(t * WaveformStore.peaksPerSecond), b = Int((t + secondsPerPixel) * WaveformStore.peaksPerSecond)
                if a >= 0 && a < peaks.count {
                    var p: Float = 0
                    for k in a...min(max(a, b), peaks.count - 1) { p = max(p, peaks[k]) }
                    let h = max(0.5, CGFloat(p) * half)
                    path.addRect(CGRect(x: x, y: mid - h, width: 1, height: h * 2))
                }
                x += 1
            }
            ctx.fill(path, with: .color(Theme.audio.opacity(0.85)))
        }
        .allowsHitTesting(false)
    }
}
