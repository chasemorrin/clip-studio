import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A finished photo or video picked from Photos, posted as is.
struct ManualItem: Identifiable {
    let id = UUID()
    let image: UIImage?
    let videoURL: URL?
    let thumbnail: UIImage
    var assetID: String? = nil
    var isVideo: Bool { videoURL != nil }
}

struct ManualImport: Identifiable, Hashable {
    let id = UUID()
    let items: [ManualItem]
    static func == (a: ManualImport, b: ManualImport) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Loads the picked photos and videos (up to 10).
    static func load(_ picks: [PhotosPickerItem]) async throws -> ManualImport {
        var items: [ManualItem] = []
        for pick in picks.prefix(10) {
            if pick.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await pick.loadTransferable(type: Movie.self) else { continue }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie.url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 400, height: 400)
                let thumb = (try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))).map { UIImage(cgImage: $0.image) }
                items.append(ManualItem(image: nil, videoURL: movie.url, thumbnail: thumb ?? UIImage(systemName: "video")!, assetID: pick.itemIdentifier))
            } else if let data = try await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                items.append(ManualItem(image: image, videoURL: nil, thumbnail: image))
            }
        }
        if items.isEmpty {
            throw APIError(code: "nothing", message: "Couldn't open those files. If they're in iCloud, open them in Photos once so they download, then try again.")
        }
        return ManualImport(items: items)
    }
}

/// Schedule or post finished media as is: add a title and caption, pick a time.
struct ManualPostView: View {
    let items: [ManualItem]

    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @State private var title = IdeaLink.title ?? ""
    @State private var caption = IdeaLink.caption ?? ""
    @State private var hashtags = DefaultHashtags.format(DefaultHashtags.list)
    @State private var when = Date().addingTimeInterval(3600)
    @State private var autoPost = true
    @State private var youtube = false
    @State private var youtubeTitle = ""
    @State private var pushBack = false
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var finished: String?

    private var instagramConnected: Bool { session.instagramUsername != nil }
    /// YouTube takes a single video (a Short), not photos or carousels.
    private var toYouTube: Bool { youtube && format == "reel" && session.youtubeChannel != nil }

    private var format: String {
        items.count > 1 ? "carousel" : (items.first?.isVideo == true ? "reel" : "photo")
    }

    private var formatLabel: String {
        switch format {
        case "carousel": return "Carousel · \(items.count) items"
        case "reel": return "Reel · posted as is"
        default: return "Photo · posted as is"
        }
    }

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            Image(uiImage: item.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 128)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottomLeading) {
                                    if item.isVideo {
                                        Image(systemName: "video.fill").font(.caption).foregroundStyle(.white)
                                            .padding(5).shadow(radius: 2)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text(formatLabel).font(.subheadline.weight(.semibold))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if items.contains(where: { $0.image.map(ClipRenderer.needsBars) ?? false }) {
                        Text("Instagram only accepts photos from 4:5 tall to 1.91:1 wide. Photos outside that get black bars so nothing is cropped.")
                    }
                    if format == "carousel" {
                        Text("Instagram shows every carousel item at the shape of the first one.")
                    }
                    if items.contains(where: \.isVideo) {
                        Text("Videos are converted to Instagram's format with no visual changes.")
                    }
                }
            }

            if let finished {
                Section {
                    Label(finished, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text("Check its progress in the Calendar tab.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("Title") {
                    TextField("Title for your calendar", text: $title)
                }
                Section {
                    CaptionEditor(text: $caption, minHeight: 120)
                } header: {
                    Text("Caption")
                }
                Section {
                    HashtagField(text: $hashtags)
                } footer: {
                    Text("Added at the end of the caption.")
                }
                WhenSection(when: $when)
                PushBackSection(day: when, isOn: $pushBack)
                InstagramPostSection(autoPost: $autoPost, busy: working != nil,
                                     postNow: { Task { await run(now: .instagram) } })
                if format == "reel" {
                    YouTubeOptionsSection(isOn: $youtube, title: $youtubeTitle, busy: working != nil,
                                          postNow: { Task { await run(now: .youtube) } })
                }
                Section {
                    Button {
                        Task { await run(now: nil) }
                    } label: {
                        Label("Schedule", systemImage: "calendar.badge.plus")
                    }
                }
                .disabled(working != nil)
            }

            if let working {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress { ProgressView(value: progress) } else { ProgressView() }
                        Text(working).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Finished post")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working != nil)
        .task {
            await posts.refresh()
            if let slot = PostingSchedule.nextSlots(1, taken: posts.takenDays).first { when = slot }
            autoPost = instagramConnected
            youtube = session.youtubeByDefault
        }
    }

    private func run(now: PostNowTarget?) async {
        error = nil
        var media: [(key: String, type: String)] = []
        do {
            for (i, item) in items.enumerated() {
                let label = items.count > 1 ? " \(i + 1) of \(items.count)" : ""
                if let url = item.videoURL {
                    working = "Preparing video\(label)…"
                    progress = 0
                    let file = try await ClipRenderer.renderAsIs(source: url) { p in
                        Task { @MainActor in progress = p }
                    }
                    working = "Uploading\(label)…"
                    progress = nil
                    media.append(try await APIClient.shared.upload(file: file, contentType: "video/mp4"))
                    try? FileManager.default.removeItem(at: file)
                } else if let image = item.image {
                    working = "Uploading\(label)…"
                    progress = nil
                    guard let data = ClipRenderer.instagramJPEG(from: image) else { continue }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                    try data.write(to: file)
                    media.append(try await APIClient.shared.upload(file: file, contentType: "image/jpeg"))
                    try? FileManager.default.removeItem(at: file)
                }
            }
            working = now == .instagram ? "Sending to Instagram…" : now == .youtube ? "Sending to YouTube…" : "Scheduling…"
            let name = title.isEmpty ? "Untitled post" : title
            let id = try await posts.create(title: name, caption: DefaultHashtags.caption(caption, tags: hashtags), format: format,
                                            media: media, at: when, autoPost: instagramConnected && autoPost,
                                            youtube: toYouTube, youtubeTitle: youtubeTitle.isEmpty ? name : youtubeTitle)
            switch now {
            case .instagram: try await posts.postNow(id: id, instagram: true, youtube: false)
            case .youtube: try await posts.postNow(id: id, instagram: false, youtube: true)
            case nil: await posts.pushBackAfterScheduling(pushBack, day: when, newID: id)
            }
            finished = now == .instagram ? "Posting to Instagram now"
                : now == .youtube ? "Posting to YouTube now"
                : "Scheduled for \(when.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }
}
