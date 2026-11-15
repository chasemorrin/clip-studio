import AVFoundation
import Photos
import QuartzCore
import UIKit

/// Turns a suggestion into a finished 9:16 clip: trimmed, standard (non-HDR) color, text overlay, soft audio edges.
enum ClipRenderer {
    static let renderSize = CGSize(width: 1080, height: 1920)

    enum RenderError: LocalizedError {
        case cantRead, cantExport
        var errorDescription: String? {
            switch self {
            case .cantRead: return "Couldn't read that video. Try choosing it again."
            case .cantExport: return "Couldn't make the clip. Try again, or restart the app if it keeps happening."
            }
        }
    }

    static func render(source: URL, start: Double, end: Double, text: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.cantRead }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.cantRead }
        try compVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        var compAudio: AVMutableCompositionTrack?
        if let audioTrack, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try t.insertTimeRange(range, of: audioTrack, at: .zero)
            compAudio = t
        }

        // Fit the footage into a vertical frame. Vertical video fills it; horizontal video sits in the middle.
        let natural = try await videoTrack.load(.naturalSize)
        let preferred = try await videoTrack.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let oriented = CGSize(width: abs(rect.width), height: abs(rect.height))
        let target = renderSize
        let portrait = oriented.height > oriented.width
        let scale = portrait ? max(target.width / oriented.width, target.height / oriented.height)
                             : min(target.width / oriented.width, target.height / oriented.height)
        let transform = preferred
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (target.width - oriented.width * scale) / 2,
                                             y: (target.height - oriented.height * scale) / 2))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.backgroundColor = UIColor.black.cgColor
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let video = AVMutableVideoComposition()
        video.renderSize = target
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [instruction]
        // Standard dynamic range output: iPhone HDR footage gets tone-mapped by AVFoundation
        // instead of looking washed out (or orange) on Instagram.
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { video.animationTool = overlay(trimmed) }

        // Short fades so the clip doesn't start or stop with a click.
        var mix: AVMutableAudioMix?
        if let compAudio {
            let p = AVMutableAudioMixInputParameters(track: compAudio)
            let d = comp.duration
            let fadeIn = CMTime(seconds: 0.12, preferredTimescale: 600)
            let fadeOut = CMTime(seconds: 0.5, preferredTimescale: 600)
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fadeIn))
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: d - fadeOut, duration: fadeOut))
            let m = AVMutableAudioMix()
            m.inputParameters = [p]
            mix = m
        }

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw RenderError.cantExport }
        session.videoComposition = video
        session.audioMix = mix
        session.shouldOptimizeForNetworkUse = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString.prefix(8)).mp4")

        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: out, as: .mp4)
        progress(1)
        return out
    }

    /// Small text near the top, over the first few seconds, fading in and out.
    private static func overlay(_ text: String) -> AVVideoCompositionCoreAnimationTool {
        let size = renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let label = CATextLayer()
        label.string = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 54, weight: .medium),
            .foregroundColor: UIColor.white,
        ])
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = 2
        label.frame = CGRect(x: 80, y: 330, width: size.width - 160, height: 160)
        label.shadowColor = UIColor.black.cgColor
        label.shadowOpacity = 0.55
        label.shadowRadius = 6
        label.shadowOffset = CGSize(width: 0, height: 2)
        label.opacity = 0

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 1, 1, 0]
        fade.keyTimes = [0, 0.077, 0.205, 0.872, 1]   // 0.3s wait, 0.5s in, hold to 3.4s, out by 3.9s
        fade.duration = 3.9
        fade.beginTime = AVCoreAnimationBeginTimeAtZero
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        label.add(fade, forKey: "fade")
        parent.addSublayer(label)

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw APIError(code: "photos_denied", message: "Clip Studio isn't allowed to save to Photos. Turn it on in Settings → Clip Studio → Photos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
