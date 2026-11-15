import AVFoundation

/// Re-encodes a finished clip to Instagram's Reels spec:
/// H.264 High, 8 Mbps, BT.709 SDR, AAC 128 kbps 48 kHz stereo, moov atom at the front.
/// Keeps files small enough to upload (about 1 MB per second).
enum InstagramEncoder {
    static let videoBitrate = 8_000_000

    /// 8 Mbps normally; lower for long videos so the file stays under the 95 MB upload limit.
    static func bitrate(forDuration seconds: Double) -> Int {
        let budget = 88.0 * 1024 * 1024 * 8 / max(1, seconds) - 128_000
        return Int(max(2_000_000, min(Double(videoBitrate), budget)))
    }

    enum EncodeError: LocalizedError {
        case noVideo, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "The clip has no video."
            case .failed(let why): return "Couldn't prepare the clip for Instagram: \(why)"
            }
        }
    }

    private final class Done: @unchecked Sendable { var value = false }

    static func encode(_ input: URL, to output: URL, bitrate: Int? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let rawDuration = try await asset.load(.duration).seconds
        let duration = max(0.1, rawDuration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw EncodeError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let size = try await videoTrack.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.alwaysCopiesSampleData = false
            reader.add(o)
            audioOut = o
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate ?? self.bitrate(forDuration: duration),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            audioIn = i
        }

        guard reader.startReading() else { throw EncodeError.failed(reader.error?.localizedDescription ?? "couldn't read it") }
        guard writer.startWriting() else { throw EncodeError.failed(writer.error?.localizedDescription ?? "couldn't write it") }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderTrackOutput, label: String, reportsProgress: Bool) {
                let done = Done()
                group.enter()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                    guard !done.value else { return }
                    while input.isReadyForMoreMediaData {
                        guard reader.status == .reading, let buffer = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            done.value = true
                            group.leave()
                            return
                        }
                        if reportsProgress {
                            progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration))
                        }
                        if !input.append(buffer) {
                            reader.cancelReading()
                            input.markAsFinished()
                            done.value = true
                            group.leave()
                            return
                        }
                    }
                }
            }
            pump(videoIn, videoOut, label: "clipstudio.encode.video", reportsProgress: true)
            if let audioIn, let audioOut { pump(audioIn, audioOut, label: "clipstudio.encode.audio", reportsProgress: false) }
            group.notify(queue: .global()) { cont.resume() }
        }

        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw EncodeError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown error")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw EncodeError.failed(writer.error?.localizedDescription ?? "the file didn't finish")
        }
    }
}
