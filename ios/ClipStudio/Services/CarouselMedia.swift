import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or video added after a clip to make a carousel. The file is copied into the app's own
/// folder so it's still there when you come back to the clip later.
struct ExtraMedia: Codable, Hashable, Identifiable {
    var id = UUID()
    var fileName: String
    var isVideo: Bool

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CarouselMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var url: URL { Self.folder.appendingPathComponent(fileName) }
    private var thumbURL: URL { Self.folder.appendingPathComponent("\(id.uuidString).thumb.jpg") }

    var thumbnail: UIImage? { UIImage(contentsOfFile: thumbURL.path) }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: thumbURL)
    }

    /// Copies picked photos and videos into the app (up to `limit`).
    static func load(_ picks: [PhotosPickerItem], limit: Int) async throws -> [ExtraMedia] {
        var out: [ExtraMedia] = []
        for pick in picks.prefix(limit) {
            let id = UUID()
            if pick.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await pick.loadTransferable(type: Movie.self) else { continue }
                let name = "\(id.uuidString).\(movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension)"
                let dest = folder.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: movie.url, to: dest)
                let item = ExtraMedia(id: id, fileName: name, isVideo: true)
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dest))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 300, height: 300)
                if let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                    try? UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)?.write(to: item.thumbURL)
                }
                out.append(item)
            } else if let data = try await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                let name = "\(id.uuidString).jpg"
                guard let jpg = image.jpegData(compressionQuality: 0.92) else { continue }
                try jpg.write(to: folder.appendingPathComponent(name))
                let item = ExtraMedia(id: id, fileName: name, isVideo: false)
                let side: CGFloat = 300
                let scale = side / max(image.size.width, image.size.height, 1)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let thumb = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                try? thumb.jpegData(compressionQuality: 0.7)?.write(to: item.thumbURL)
                out.append(item)
            }
        }
        return out
    }

    /// Prepares each item for Instagram and uploads it. Reports progress as (label, fraction or nil).
    @MainActor
    static func upload(_ items: [ExtraMedia], status: @escaping (String, Double?) -> Void) async throws -> [(key: String, type: String)] {
        var media: [(key: String, type: String)] = []
        for (i, item) in items.enumerated() {
            let label = "item \(i + 2) of \(items.count + 1)"
            if item.isVideo {
                status("Preparing \(label)…", 0)
                let file = try await ClipRenderer.renderAsIs(source: item.url) { p in
                    Task { @MainActor in status("Preparing \(label)…", p) }
                }
                status("Uploading \(label)…", nil)
                media.append(try await APIClient.shared.upload(file: file, contentType: "video/mp4"))
                try? FileManager.default.removeItem(at: file)
            } else {
                status("Uploading \(label)…", nil)
                guard let image = UIImage(contentsOfFile: item.url.path), let data = ClipRenderer.instagramJPEG(from: image) else { continue }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: file)
                media.append(try await APIClient.shared.upload(file: file, contentType: "image/jpeg"))
                try? FileManager.default.removeItem(at: file)
            }
        }
        return media
    }
}

/// YouTube Shorts show the title with its hashtags, so they go at the end of the title.
enum YouTubeText {
    static let limit = 100

    /// Title plus hashtags, as YouTube will show it (may be over the limit).
    static func fullTitle(_ base: String, tags: [String]) -> String {
        let t = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = DefaultHashtags.format(tags)
        if h.isEmpty { return t }
        return t.isEmpty ? h : "\(t) \(h)"
    }

    /// What's actually sent: the title plus as many hashtags as fit in 100 characters.
    static func title(_ base: String, tags: [String]) -> String {
        var kept = tags
        while !kept.isEmpty && fullTitle(base, tags: kept).count > limit { kept.removeLast() }
        return String(fullTitle(base, tags: kept).prefix(limit))
    }

    /// Hashtags that won't fit in the title.
    static func leftOff(_ base: String, tags: [String]) -> [String] {
        var kept = tags
        while !kept.isEmpty && fullTitle(base, tags: kept).count > limit { kept.removeLast() }
        return Array(tags.dropFirst(kept.count))
    }

    /// Splits a saved title back into its words and its trailing hashtags.
    static func split(_ title: String) -> (base: String, tags: [String]) {
        var words = title.split(separator: " ").map(String.init)
        var tags: [String] = []
        while let last = words.last, last.hasPrefix("#"), last.count > 1 {
            tags.insert(String(last.dropFirst()), at: 0)
            words.removeLast()
        }
        return (words.joined(separator: " "), tags)
    }
}

/// While something long runs (making and uploading a post): a card in the middle of the screen,
/// above everything, so it can't be missed.
struct WorkingOverlay: ViewModifier {
    let working: String?
    let progress: Double?

    func body(content: Content) -> some View {
        content.overlay {
            if let working {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 14) {
                        if let progress {
                            ProgressView(value: progress)
                                .frame(width: 220)
                            Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.large)
                        }
                        Text(working).font(.headline).multilineTextAlignment(.center)
                        Text("Keep Clip Studio open until this finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 20)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: working == nil)
    }
}

extension View {
    func workingOverlay(_ working: String?, progress: Double?) -> some View {
        modifier(WorkingOverlay(working: working, progress: progress))
    }
}

/// Asks iOS for extra time if you leave the app while a post is uploading.
enum BackgroundWork {
    @MainActor
    static func run<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        return try await work()
    }
}

/// How the Short's title will look on YouTube (title + hashtags), with a warning when it's too long.
struct YouTubeTitlePreview: View {
    let base: String
    let tags: [String]

    var body: some View {
        let full = YouTubeText.fullTitle(base, tags: tags)
        let leftOff = YouTubeText.leftOff(base, tags: tags)
        VStack(alignment: .leading, spacing: 3) {
            Text("Title on YouTube").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(full.isEmpty ? "—" : full).font(.callout)
            if full.count > YouTubeText.limit {
                Text(leftOff.isEmpty
                     ? "\(full.count)/\(YouTubeText.limit) characters: too long for YouTube. The title will be cut short."
                     : "\(full.count)/\(YouTubeText.limit) characters: too long for YouTube, so these hashtags will be left off: \(DefaultHashtags.format(leftOff))")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("\(full.count)/\(YouTubeText.limit) characters").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Add photos or videos after the clip to post a carousel on Instagram.
struct CarouselEditor: View {
    @Binding var items: [ExtraMedia]
    @State private var picks: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var error: String?

    private let maxExtras = 9  // Instagram allows 10 items, and the clip is the first

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.fill").foregroundStyle(Theme.accent)
                Text("Carousel").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                PhotosPicker(selection: $picks, maxSelectionCount: max(1, maxExtras - items.count),
                             matching: .any(of: [.images, .videos])) {
                    Label(items.isEmpty ? "Add photos or videos" : "Add more", systemImage: "plus")
                }
                .font(.footnote)
                .disabled(items.count >= maxExtras || loading)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        tile(label: "Clip") {
                            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            tile(label: "\(i + 2)") {
                                if let thumb = item.thumbnail {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                } else {
                                    Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(.secondary)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    item.delete()
                                    items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.title3)
                                }
                                .padding(2)
                                .accessibilityLabel("Remove item \(i + 2)")
                            }
                            .overlay(alignment: .bottomLeading) {
                                if item.isVideo {
                                    Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(items.isEmpty
                 ? "Add photos or videos after the clip to post a carousel on Instagram."
                 : "Posts on Instagram as a carousel of \(items.count + 1): the clip first, then these. Instagram shows every item at the shape of the first. YouTube gets just the clip.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            Task {
                loading = true
                error = nil
                defer { loading = false; picks = [] }
                do {
                    items += try await ExtraMedia.load(new, limit: maxExtras - items.count)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func tile<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(width: 64, height: 86)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
    }
}
