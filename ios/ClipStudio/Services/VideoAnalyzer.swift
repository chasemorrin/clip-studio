import AVFoundation
import CoreGraphics
import UIKit

/// What the phone learns about a video before asking Claude.
struct VideoAnalysis {
    struct Frame {
        let time: Double
        let image: CGImage
    }

    let url: URL
    let duration: Double
    let hop: Double                 // seconds per audio step
    let loudness: [Float]           // dB per step, smoothed
    let activity: [Float]           // 0...1, how busy the music is (note onsets)
    let noisiness: [Float]          // 0...1, hiss/applause-like sound
    let breaths: [Double]           // quiet dips between phrases: good cut points
    let sections: [ClosedRange<Double>] // stretches where the camera holds one shot
    let frames: [Frame]
    let isPortrait: Bool

    /// Loudness scaled 0...1 for drawing a waveform.
    var waveform: [Float] {
        guard let lo = loudness.min(), let hi = loudness.max(), hi > lo else { return loudness.map { _ in 0.5 } }
        return loudness.map { ($0 - lo) / (hi - lo) }
    }

    func nearestBreath(to t: Double, within window: Double = 3) -> Double? {
        breaths.min(by: { abs($0 - t) < abs($1 - t) }).flatMap { abs($0 - t) <= window ? $0 : nil }
    }
}

enum AnalyzerError: LocalizedError {
    case noVideo, noAudio, tooShort
    var errorDescription: String? {
        switch self {
        case .noVideo: return "That file doesn't have a video track."
        case .noAudio: return "That video has no sound, so there's nothing to find phrases in."
        case .tooShort: return "That video is too short. Pick one that's at least 20 seconds long."
        }
    }
}

enum VideoAnalyzer {
    static let sampleRate: Double = 11025
    static let hop: Double = 0.25

    static func analyze(url: URL, progress: @escaping @Sendable (Double, String) -> Void) async throws -> VideoAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration >= 20 else { throw AnalyzerError.tooShort }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw AnalyzerError.noVideo }
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalyzerError.noAudio }

        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let isPortrait = abs(oriented.height) > abs(oriented.width)

        progress(0.05, "Listening to the audio…")
        let samples = try readAudio(asset: asset, track: audioTrack, duration: duration) { p in progress(0.05 + p * 0.45, "Listening to the audio…") }
        let audio = measure(samples: samples)

        progress(0.5, "Looking at the footage…")
        let (frames, sections) = try await scanFrames(asset: asset, duration: duration) { p in progress(0.5 + p * 0.45, "Looking at the footage…") }

        progress(1, "Done")
        return VideoAnalysis(url: url, duration: duration, hop: hop, loudness: audio.loudness, activity: audio.activity,
                             noisiness: audio.noisiness, breaths: audio.breaths, sections: sections, frames: frames, isPortrait: isPortrait)
    }

    // MARK: Audio

    private static func readAudio(asset: AVAsset, track: AVAssetTrack, duration: Double, progress: (Double) -> Void) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalyzerError.noAudio }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * sampleRate) + 1024)
        var lastReport = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                chunk.withUnsafeMutableBytes { ptr in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            }
            let p = Double(samples.count) / (duration * sampleRate)
            if p - lastReport > 0.05 { lastReport = p; progress(min(1, p)) }
        }
        if reader.status == .failed { throw reader.error ?? AnalyzerError.noAudio }
        return samples
    }

    private static func measure(samples: [Float]) -> (loudness: [Float], activity: [Float], noisiness: [Float], breaths: [Double]) {
        let win = Int(sampleRate * hop)
        let sub = 256
        let n = samples.count / win
        var db = [Float](repeating: -80, count: n)
        var onset = [Float](repeating: 0, count: n)
        var zcr = [Float](repeating: 0, count: n)
        var prevSubLog: Float = -10

        samples.withUnsafeBufferPointer { s in
            for i in 0..<n {
                let start = i * win
                var sumSq: Float = 0
                var crossings = 0
                var flux: Float = 0
                var j = 0
                while j < win {
                    let end = min(j + sub, win)
                    var e: Float = 0
                    for k in j..<end {
                        let v = s[start + k]
                        e += v * v
                        if k > 0, (v >= 0) != (s[start + k - 1] >= 0) { crossings += 1 }
                    }
                    sumSq += e
                    let lg = log10(e / Float(end - j) + 1e-9)
                    flux += max(0, lg - prevSubLog)
                    prevSubLog = lg
                    j = end
                }
                db[i] = 10 * log10(sumSq / Float(win) + 1e-10)
                onset[i] = flux
                zcr[i] = Float(crossings) / Float(win)
            }
        }

        let smooth = movingAverage(db, radius: 2)
        let activity = normalize(movingAverage(onset, radius: 2))
        let noisiness = normalize(movingAverage(zcr, radius: 4))

        // Breaths: local minimum of loudness, clearly below the surrounding ~8 seconds.
        var breaths: [Double] = []
        let local = Int(1.0 / hop), context = Int(4.0 / hop)
        if n > 2 * local {
            for i in local..<(n - local) {
                let v = smooth[i]
                var isMin = true
                for k in (i - local)...(i + local) where smooth[k] < v { isMin = false; break }
                guard isMin else { continue }
                let lo = max(0, i - context), hi = min(n - 1, i + context)
                let mean = smooth[lo...hi].reduce(0, +) / Float(hi - lo + 1)
                if v <= mean - 2.0 {
                    let t = Double(i) * hop + hop / 2
                    if let last = breaths.last, t - last < 1.5 { continue }
                    breaths.append(t)
                }
            }
        }
        return (smooth, activity, noisiness, breaths)
    }

    private static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        guard !x.isEmpty else { return x }
        var out = [Float](repeating: 0, count: x.count)
        for i in x.indices {
            let lo = max(0, i - radius), hi = min(x.count - 1, i + radius)
            out[i] = x[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
        return out
    }

    private static func normalize(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let sorted = x.sorted()
        let lo = sorted[Int(Double(sorted.count - 1) * 0.05)]
        let hi = sorted[Int(Double(sorted.count - 1) * 0.95)]
        guard hi > lo else { return x.map { _ in 0.5 } }
        return x.map { min(1, max(0, ($0 - lo) / (hi - lo))) }
    }

    // MARK: Footage

    private static func scanFrames(asset: AVAsset, duration: Double, progress: (Double) -> Void) async throws -> ([VideoAnalysis.Frame], [ClosedRange<Double>]) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = max(2.0, duration / 150)
        var frames: [VideoAnalysis.Frame] = []
        var signatures: [[Float]] = []
        var t = 0.5
        while t < duration - 0.5 {
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                frames.append(.init(time: t, image: result.image))
                signatures.append(signature(result.image))
            }
            progress(t / duration)
            t += step
        }

        // A big change between neighbouring frames = a new camera shot.
        var diffs: [Float] = [0]
        for i in 1..<max(1, signatures.count) {
            diffs.append(zip(signatures[i], signatures[i - 1]).map { abs($0 - $1) }.reduce(0, +) / Float(signatures[i].count))
        }
        let median = diffs.sorted()[diffs.count / 2]
        let threshold = max(0.07, median * 3)
        var sections: [ClosedRange<Double>] = []
        var sectionStart = 0.0
        for i in 1..<max(1, frames.count) where diffs[i] > threshold {
            let cut = (frames[i - 1].time + frames[i].time) / 2
            if cut - sectionStart >= 4 { sections.append(sectionStart...cut); sectionStart = cut }
        }
        sections.append(sectionStart...duration)
        return (frames, sections)
    }

    /// An 8x8 colour thumbnail as numbers, for comparing shots.
    private static func signature(_ image: CGImage) -> [Float] {
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [Float](repeating: 0, count: w * h * 3) }
        var out: [Float] = []
        out.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) {
            out.append(Float(pixels[i * 4]) / 255)
            out.append(Float(pixels[i * 4 + 1]) / 255)
            out.append(Float(pixels[i * 4 + 2]) / 255)
        }
        return out
    }
}
