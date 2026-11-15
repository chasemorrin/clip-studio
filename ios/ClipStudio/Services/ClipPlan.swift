import Foundation
import Photos
import AVFoundation

/// Everything needed to reopen a scheduled clip in the editor: which video in Photos it came from,
/// the trim, text and framing. Stored with the post on the server.
struct ClipPlan: Codable, Hashable {
    var kind = "clip"
    var assetId: String
    var start: Double
    var end: Double
    var title: String
    var onScreenText: String
    var caption: String
    var hashtags: [String]
    var why: String
    var zoom: Double?
    var offsetX: Double?
    var offsetY: Double?

    init(clip: ClipSuggestion, assetId: String) {
        self.assetId = assetId
        start = clip.start
        end = clip.end
        title = clip.title
        onScreenText = clip.onScreenText
        caption = clip.caption
        hashtags = clip.hashtags
        why = clip.why
        zoom = clip.framing?.zoom
        offsetX = clip.framing?.offsetX
        offsetY = clip.framing?.offsetY
    }

    /// The suggestion to put back in the editor.
    var suggestion: ClipSuggestion {
        var c = ClipSuggestion(start: start, end: end, title: title, why: why, onScreenText: onScreenText,
                               caption: caption, hashtags: hashtags)
        if let zoom { c.framing = Framing(zoom: zoom, offsetX: offsetX ?? 0, offsetY: offsetY ?? 0) }
        c.keep = true
        return c
    }

    /// As a JSON object for the server.
    var json: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any], dict["kind"] as? String == "clip",
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let plan = try? JSONDecoder().decode(ClipPlan.self, from: data) else { return nil }
        self = plan
    }
}

enum SourceVideo {
    enum LoadError: LocalizedError {
        case noAccess, missing, unsupported
        var errorDescription: String? {
            switch self {
            case .noAccess: return "Clip Studio needs access to your photo library to reopen the original video. Allow it in Settings → Clip Studio → Photos."
            case .missing: return "The original video isn't in your photo library anymore. You can still change the title, caption and time."
            case .unsupported: return "That video can't be reopened (it may be a slow-motion or edited version). You can still change the title, caption and time."
            }
        }
    }

    /// Finds the original video in Photos (downloading it from iCloud if needed) and returns a file URL.
    static func load(assetId: String) async throws -> URL {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { throw LoadError.noAccess }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { throw LoadError.missing }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let url = (avAsset as? AVURLAsset)?.url {
                    cont.resume(returning: url)
                } else if (info?[PHImageErrorKey] as? Error) != nil {
                    cont.resume(throwing: LoadError.missing)
                } else {
                    cont.resume(throwing: LoadError.unsupported)
                }
            }
        }
    }
}
