import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video chosen from Photos, copied into the app's temporary folder.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("footage-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Movie(url: dest)
        }
    }
}

struct Footage: Hashable, Identifiable {
    let url: URL
    let useClaude: Bool
    var assetID: String? = nil
    var id: URL { url }
}

enum PickMode: String, CaseIterable, Identifiable {
    case claude, device, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .device: return "On-device"
        case .manual: return "Manual"
        }
    }
    var explanation: String {
        switch self {
        case .claude: return "Claude looks at frames and the audio map and suggests the best moments. Uses one Claude request."
        case .device: return "Picks the busiest stretches from the audio alone. Free, works offline, less musical."
        case .manual: return "Use a whole video or your own photos as is. Trim, frame, caption and schedule them yourself."
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var session: SessionStore
    @AppStorage("pickMode") private var modeRaw = PickMode.claude.rawValue
    @State private var pick: PhotosPickerItem?
    @State private var manualPicks: [PhotosPickerItem] = []
    @State private var footage: Footage?
    @State private var manualVideo: Footage?
    @State private var photos: PhotoImport?
    @State private var mixed: ManualImport?
    @State private var loading = false
    @State private var error: String?

    private var mode: PickMode { PickMode(rawValue: modeRaw) ?? .claude }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "film.stack")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(spacing: 8) {
                    Text("Make a post")
                        .font(.title2.weight(.semibold))
                    Text("Pick a concert or practice video and let Claude find the moments, or bring your own finished video or photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick clips with").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Pick clips with", selection: $modeRaw) {
                        ForEach(PickMode.allCases) { m in Text(m.label).tag(m.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if mode == .manual {
                        PhotosPicker(selection: $manualPicks, maxSelectionCount: 10, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                            buttonLabel(loading ? "Opening…" : "Choose video or photos")
                        }
                    } else {
                        PhotosPicker(selection: $pick, matching: .videos, photoLibrary: .shared()) {
                            buttonLabel(loading ? "Opening video…" : "Choose footage")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
                if loading { ProgressView() }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Clip Studio")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $footage) { f in ProjectView(url: f.url, useClaude: f.useClaude, assetID: f.assetID) }
            .navigationDestination(item: $manualVideo) { f in ManualVideoView(url: f.url, assetID: f.assetID) }
            .navigationDestination(item: $photos) { p in PhotoPostView(images: p.images) }
            .navigationDestination(item: $mixed) { m in ManualPostView(items: m.items) }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task { await loadFootage(item) }
            }
            .onChange(of: manualPicks) { _, picks in
                guard !picks.isEmpty else { return }
                Task { await loadManual(picks) }
            }
            .task { await session.refreshProfile() }
        }
    }

    private func buttonLabel(_ text: String) -> some View {
        Label(text, systemImage: mode == .manual ? "photo.on.rectangle.angled" : "video.badge.plus")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    private func loadFootage(_ item: PhotosPickerItem) async {
        loading = true
        error = nil
        defer { loading = false; pick = nil }
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                error = "Couldn't open that video. If it's in iCloud, open it in Photos once so it downloads, then try again."
                return
            }
            footage = Footage(url: movie.url, useClaude: mode == .claude, assetID: item.itemIdentifier)
        } catch {
            self.error = "Couldn't open that video: \(error.localizedDescription)"
        }
    }

    /// Manual: one video opens the editor with the whole video; photos open the photo screen;
    /// a mix of several videos/photos is posted as is.
    private func loadManual(_ picks: [PhotosPickerItem]) async {
        loading = true
        error = nil
        defer { loading = false; manualPicks = [] }
        do {
            let imported = try await ManualImport.load(picks)
            let videos = imported.items.filter(\.isVideo)
            if imported.items.count == 1, let v = videos.first, let url = v.videoURL {
                manualVideo = Footage(url: url, useClaude: false, assetID: v.assetID)
            } else if videos.isEmpty {
                photos = PhotoImport(images: imported.items.compactMap(\.image))
            } else {
                mixed = imported
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
