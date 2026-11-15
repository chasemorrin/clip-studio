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
    @State private var title = ""
    @State private var caption = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var autoPost = true
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var finished: String?

    private var instagramConnected: Bool { session.instagramUsername != nil }

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
                } footer: {
                    Text("Add hashtags at the end of the caption.")
                }
                Section {
                    DatePicker("Post on", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("Post to Instagram automatically", isOn: $autoPost).disabled(!instagramConnected)
                } header: {
                    Text("When")
                } footer: {
                    if !instagramConnected { Text("Connect Instagram in Settings to post automatically.") }
                }
                Section {
                    Button {
                        Task { await run(postNow: false) }
                    } label: {
                        Label("Schedule", systemImage: "calendar.badge.plus")
                    }
                    if instagramConnected {
                        Button {
                            Task { await run(postNow: true) }
                        } label: {
                            Label("Post to Instagram now", systemImage: "paperplane.fill")
                        }
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
        .navigationTitle("Finished post")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working != nil)
        .task {
            await posts.refresh()
            if let slot = PostingSchedule.nextSlots(1, taken: posts.takenDays).first { when = slot }
            autoPost = instagramConnected
        }
    }

    private func run(postNow: Bool) async {
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
            working = postNow ? "Sending to Instagram…" : "Scheduling…"
            let at = postNow ? Date() : when
            let id = try await posts.create(title: title.isEmpty ? "Untitled post" : title, caption: caption, format: format,
                                            media: media, at: at, autoPost: postNow || (autoPost && instagramConnected))
            if postNow { try await posts.postNow(id: id) }
            finished = postNow ? "Posting to Instagram now" : "Scheduled for \(at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }
}
