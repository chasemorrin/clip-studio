import Foundation
import Photos
import UIKit

/// A video you've found clips in, saved so you can come back to its clips later.
struct SavedProject: Codable, Identifiable, Hashable {
    let id: UUID
    var assetID: String
    var useClaude: Bool
    var createdAt: Date
    var videoDate: Date?
    var duration: Double
    var clipCount: Int
    var keptCount: Int
    var scheduledCount: Int
    var note: String?

    var name: String {
        (videoDate ?? createdAt).formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The parts of a video's analysis worth keeping, so reopening a project doesn't analyze the video again.
private struct CachedAnalysis: Codable {
    var duration: Double
    var hop: Double
    var loudness: [Float]
    var activity: [Float]
    var noisiness: [Float]
    var breaths: [Double]
    var sections: [[Double]]
    var frameTimes: [Double]
    var frameJPEGs: [Data]
    var isPortrait: Bool
    var width: Double
    var height: Double

    init(_ a: VideoAnalysis) {
        duration = a.duration
        hop = a.hop
        loudness = a.loudness
        activity = a.activity
        noisiness = a.noisiness
        breaths = a.breaths
        sections = a.sections.map { [$0.lowerBound, $0.upperBound] }
        frameTimes = a.frames.map(\.time)
        frameJPEGs = a.frames.map { UIImage(cgImage: $0.image).jpegData(compressionQuality: 0.7) ?? Data() }
        isPortrait = a.isPortrait
        width = Double(a.sourceSize.width)
        height = Double(a.sourceSize.height)
    }

    func analysis(url: URL, assetID: String) -> VideoAnalysis {
        let frames: [VideoAnalysis.Frame] = zip(frameTimes, frameJPEGs).compactMap { t, data in
            UIImage(data: data)?.cgImage.map { VideoAnalysis.Frame(time: t, image: $0) }
        }
        var a = VideoAnalysis(url: url, duration: duration, hop: hop, loudness: loudness, activity: activity,
                              noisiness: noisiness, breaths: breaths,
                              sections: sections.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil },
                              frames: frames, isPortrait: isPortrait, sourceSize: CGSize(width: width, height: height))
        a.sourceAssetID = assetID
        return a
    }
}

/// Keeps saved projects in the app's own folder on the phone.
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published private(set) var projects: [SavedProject] = []

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL { folder.appendingPathComponent("projects.json") }
    private func file(_ id: UUID, _ suffix: String) -> URL { folder.appendingPathComponent("\(id.uuidString).\(suffix)") }

    private init() {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([SavedProject].self, from: data) {
            projects = list
        }
    }

    func project(forAsset assetID: String) -> SavedProject? {
        projects.first { $0.assetID == assetID }
    }

    /// Saves a project's clips (and, the first time, its analysis and a thumbnail).
    func save(id: UUID, assetID: String, useClaude: Bool, analysis: VideoAnalysis, clips: [ClipSuggestion], note: String?) {
        let isNew = !projects.contains { $0.id == id }
        if isNew || !FileManager.default.fileExists(atPath: file(id, "analysis").path) {
            if let data = try? PropertyListEncoder().encode(CachedAnalysis(analysis)) {
                try? data.write(to: file(id, "analysis"), options: .atomic)
            }
            if let thumb = thumbnailImage(analysis, clips: clips), let jpg = thumb.jpegData(compressionQuality: 0.7) {
                try? jpg.write(to: file(id, "jpg"), options: .atomic)
            }
        }
        if let data = try? JSONEncoder().encode(clips) {
            try? data.write(to: file(id, "clips"), options: .atomic)
        }
        var p = projects.first { $0.id == id } ?? SavedProject(
            id: id, assetID: assetID, useClaude: useClaude, createdAt: Date(), videoDate: Self.videoDate(assetID),
            duration: analysis.duration, clipCount: 0, keptCount: 0, scheduledCount: 0, note: nil)
        p.clipCount = clips.count
        p.keptCount = clips.filter(\.keep).count
        p.scheduledCount = clips.filter { $0.scheduledFor != nil }.count
        p.note = note
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i] = p } else { projects.insert(p, at: 0) }
        writeIndex()
    }

    func clips(for id: UUID) -> [ClipSuggestion]? {
        guard let data = try? Data(contentsOf: file(id, "clips")) else { return nil }
        return try? JSONDecoder().decode([ClipSuggestion].self, from: data)
    }

    func analysis(for project: SavedProject, url: URL) -> VideoAnalysis? {
        guard let data = try? Data(contentsOf: file(project.id, "analysis")),
              let cached = try? PropertyListDecoder().decode(CachedAnalysis.self, from: data) else { return nil }
        return cached.analysis(url: url, assetID: project.assetID)
    }

    func thumbnail(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: file(id, "jpg").path)
    }

    func delete(_ id: UUID) {
        for suffix in ["clips", "analysis", "jpg"] { try? FileManager.default.removeItem(at: file(id, suffix)) }
        projects.removeAll { $0.id == id }
        writeIndex()
    }

    private func writeIndex() {
        if let data = try? JSONEncoder().encode(projects) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// A frame near the first clip, for the list.
    private func thumbnailImage(_ a: VideoAnalysis, clips: [ClipSuggestion]) -> UIImage? {
        let t = clips.first.map { ($0.start + $0.end) / 2 } ?? a.duration / 2
        guard let f = a.frames.min(by: { abs($0.time - t) < abs($1.time - t) }) else { return nil }
        let img = UIImage(cgImage: f.image)
        let target = CGSize(width: 160, height: 160 * img.size.height / max(img.size.width, 1))
        return UIGraphicsImageRenderer(size: target).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// When the video was filmed, if the app can see the photo library.
    private static func videoDate(_ assetID: String) -> Date? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject?.creationDate
    }
}
