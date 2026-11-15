import SwiftUI
import UIKit

struct PhotoImport: Identifiable, Hashable {
    let id = UUID()
    let images: [UIImage]
    static func == (a: PhotoImport, b: PhotoImport) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The frame shapes Instagram accepts for photos.
enum PhotoShape: String, CaseIterable, Identifiable {
    case portrait, square, landscape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .landscape: return "1.91:1"
        }
    }
    /// Output size in pixels.
    var size: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1080, height: 566)
        }
    }
    static func best(for image: UIImage) -> PhotoShape {
        let r = image.size.width / max(1, image.size.height)
        return r >= 1.3 ? .landscape : r >= 0.9 ? .square : .portrait
    }
}

/// How a photo sits in its frame: zoom 1 = whole photo visible.
struct PhotoCrop: Hashable {
    var zoom: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0

    static func fitScale(_ img: CGSize, _ canvas: CGSize) -> Double {
        Double(min(canvas.width / img.width, canvas.height / img.height))
    }
    static func fillZoom(_ img: CGSize, _ canvas: CGSize) -> Double {
        Double(max(canvas.width / img.width, canvas.height / img.height)) / fitScale(img, canvas)
    }
    static func fill(_ img: CGSize, _ canvas: CGSize) -> PhotoCrop { PhotoCrop(zoom: fillZoom(img, canvas)) }

    func placed(_ img: CGSize, _ canvas: CGSize) -> CGRect {
        let s = PhotoCrop.fitScale(img, canvas) * zoom
        let w = Double(img.width) * s, h = Double(img.height) * s
        return CGRect(x: (Double(canvas.width) - w) / 2 + offsetX, y: (Double(canvas.height) - h) / 2 + offsetY, width: w, height: h)
    }

    func clamped(_ img: CGSize, _ canvas: CGSize) -> PhotoCrop {
        var c = self
        c.zoom = min(max(1, c.zoom), max(5, PhotoCrop.fillZoom(img, canvas) * 3))
        let r = c.placed(img, canvas)
        let maxX = max(0, (Double(r.width) - Double(canvas.width)) / 2)
        let maxY = max(0, (Double(r.height) - Double(canvas.height)) / 2)
        c.offsetX = min(maxX, max(-maxX, c.offsetX))
        c.offsetY = min(maxY, max(-maxY, c.offsetY))
        return c
    }

    func crops(_ img: CGSize, _ canvas: CGSize) -> Bool {
        let r = placed(img, canvas)
        return r.width > canvas.width + 1 || r.height > canvas.height + 1
    }

    /// The finished JPEG, exactly as the preview shows it.
    func render(_ image: UIImage, canvas: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: placed(image.size, canvas))
        }
        return out.jpegData(compressionQuality: 0.9)
    }
}

/// One photo in its frame. Pinch to zoom, drag to move.
struct PhotoCanvas: View {
    let image: UIImage
    let canvas: CGSize
    @Binding var crop: PhotoCrop
    @State private var pinchBase: PhotoCrop?
    @State private var dragBase: PhotoCrop?

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / canvas.width
            let r = crop.placed(image.size, canvas)
            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .frame(width: r.width * k, height: r.height * k)
                    .position(x: r.midX * k, y: r.midY * k)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { g in
                            if pinchBase == nil { pinchBase = crop }
                            var c = pinchBase ?? crop
                            c.zoom *= Double(g.magnification)
                            crop = c.clamped(image.size, canvas)
                        }
                        .onEnded { _ in pinchBase = nil },
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            if dragBase == nil { dragBase = crop }
                            var c = dragBase ?? crop
                            c.offsetX += Double(g.translation.width / k)
                            c.offsetY += Double(g.translation.height / k)
                            crop = c.clamped(image.size, canvas)
                        }
                        .onEnded { _ in dragBase = nil }
                )
            )
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
    }
}

/// Manual mode with photos: frame each one, add a title and caption, then schedule or post.
struct PhotoPostView: View {
    let images: [UIImage]

    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @State private var shape: PhotoShape = .portrait
    @State private var crops: [PhotoCrop] = []
    @State private var current = 0
    @State private var title = ""
    @State private var caption = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var earliest = Date()
    @State private var autoPost = true
    @State private var working: String?
    @State private var error: String?
    @State private var finished: String?

    private var instagramConnected: Bool { session.instagramUsername != nil }
    private var canvas: CGSize { shape.size }

    private func cropBinding(_ i: Int) -> Binding<PhotoCrop> {
        Binding(get: { i < crops.count ? crops[i] : PhotoCrop() },
                set: { if i < crops.count { crops[i] = $0 } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !images.isEmpty, current < images.count {
                    PhotoCanvas(image: images[current], canvas: canvas, crop: cropBinding(current))
                        .frame(maxHeight: 460)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .id("\(current)-\(shape.rawValue)")
                }

                if images.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images.indices, id: \.self) { i in
                                Image(uiImage: images[i])
                                    .resizable().scaledToFill()
                                    .frame(width: 56, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == current ? Theme.accent : .clear, lineWidth: 3))
                                    .onTapGesture { current = i }
                            }
                        }
                    }
                    Text("Carousel · \(images.count) photos. Tap a photo to frame it.").font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Shape", selection: $shape) {
                        ForEach(PhotoShape.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                    if current < images.count, current < crops.count {
                        let img = images[current].size
                        HStack(spacing: 8) {
                            Button("Whole photo") { crops[current] = PhotoCrop() }
                            Button("Fill frame") { crops[current] = PhotoCrop.fill(img, canvas) }
                            Spacer()
                            Text(crops[current].crops(img, canvas) ? String(format: "Zoom %.1f×", crops[current].zoom) : "No crop")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("Pinch to zoom, drag to move. The post matches this preview. Instagram shows every carousel photo at the same shape.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let finished {
                    Label(finished, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.headline)
                    Text("Check its progress in the Calendar tab.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Title for your calendar", text: $title).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Caption").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        CaptionEditor(text: $caption, minHeight: 110)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker("Post on", selection: $when, in: earliest..., displayedComponents: [.date, .hourAndMinute])
                        Toggle("Post to Instagram automatically", isOn: $autoPost).disabled(!instagramConnected)
                        if !instagramConnected {
                            Text("Connect Instagram in Settings to post automatically.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 10) {
                        Button {
                            Task { await run(postNow: false) }
                        } label: {
                            Label("Schedule", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        if instagramConnected {
                            Button {
                                Task { await run(postNow: true) }
                            } label: {
                                Label("Post to Instagram now", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .disabled(working != nil)
                }

                if let working {
                    HStack(spacing: 8) { ProgressView(); Text(working).font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .padding()
        }
        .navigationTitle(images.count > 1 ? "Carousel" : "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard crops.isEmpty, let first = images.first else { return }
            shape = PhotoShape.best(for: first)
            crops = images.map { PhotoCrop.fill($0.size, shape.size) }
        }
        .onChange(of: shape) { _, s in
            crops = images.map { PhotoCrop.fill($0.size, s.size) }
        }
        .task {
            await posts.refresh()
            earliest = Date()
            if let slot = PostingSchedule.nextSlots(1, taken: posts.takenDays).first { when = slot }
            autoPost = instagramConnected
        }
    }

    private func run(postNow: Bool) async {
        error = nil
        var media: [(key: String, type: String)] = []
        do {
            for (i, image) in images.enumerated() {
                working = images.count > 1 ? "Uploading photo \(i + 1) of \(images.count)…" : "Uploading…"
                let crop = i < crops.count ? crops[i] : PhotoCrop.fill(image.size, canvas)
                guard let data = crop.render(image, canvas: canvas) else { continue }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: file)
                media.append(try await APIClient.shared.upload(file: file, contentType: "image/jpeg"))
                try? FileManager.default.removeItem(at: file)
            }
            working = postNow ? "Sending to Instagram…" : "Scheduling…"
            let at = postNow ? Date() : when
            let id = try await posts.create(title: title.isEmpty ? "Untitled post" : title, caption: caption,
                                            format: images.count > 1 ? "carousel" : "photo",
                                            media: media, at: at, autoPost: postNow || (autoPost && instagramConnected))
            if postNow { try await posts.postNow(id: id) }
            finished = postNow ? "Posting to Instagram now" : "Scheduled for \(at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }
}
