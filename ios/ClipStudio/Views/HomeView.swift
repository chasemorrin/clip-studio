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

/// A saved project to open, with the video file if it's already been loaded.
struct OpenSaved: Hashable {
    let project: SavedProject
    var url: URL? = nil
}

struct HomeView: View {
    @EnvironmentObject var session: SessionStore
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var ideaLink = IdeaLink.shared
    @State private var openSaved: OpenSaved?
    @State private var confirmDelete: SavedProject?
    @AppStorage("pickMode") private var modeRaw = PickMode.claude.rawValue
    /// The video picked and shown in the preview, waiting for "Find clips" / "Edit this video".
    @State private var selected: Footage?
    @State private var pick: PhotosPickerItem?
    @State private var manualPicks: [PhotosPickerItem] = []
    @State private var footage: Footage?
    @State private var manualVideo: Footage?
    @State private var photos: PhotoImport?
    @State private var mixed: ManualImport?
    @State private var loading = false
    @State private var error: String?

    private var mode: PickMode { PickMode(rawValue: modeRaw) ?? .claude }
    private var savedForSelected: SavedProject? { selected?.assetID.flatMap { store.project(forAsset: $0) } }

    var body: some View {
        NavigationStack {
          ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48, weight: .light))
                    Text("Clip Studio")
                }
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Clip Studio")
                .accessibilityAddTraits(.isHeader)
                if let idea = ideaLink.idea {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Making a post for your idea").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(idea.title.isEmpty ? "Untitled idea" : idea.title).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Button("Cancel") { ideaLink.finish() }.font(.subheadline)
                    }
                    .padding(12)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
                if let day = ideaLink.plannedDay {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Making a post for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Button("Cancel") { ideaLink.plannedDay = nil }.font(.subheadline)
                    }
                    .padding(12)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }
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
                if let selected {
                    Button {
                        if mode == .manual {
                            manualVideo = Footage(url: selected.url, useClaude: false, assetID: selected.assetID)
                        } else {
                            footage = Footage(url: selected.url, useClaude: mode == .claude, assetID: selected.assetID)
                        }
                    } label: {
                        buttonLabel(mode == .manual ? "Edit this video" : "Find clips",
                                    icon: mode == .manual ? "scissors" : mode == .claude ? "sparkles" : "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    VStack(alignment: .leading, spacing: 10) {
                        FootagePreview(url: selected.url)
                        if let saved = savedForSelected {
                            Button {
                                openSaved = OpenSaved(project: saved, url: selected.url)
                            } label: {
                                Label("Already scanned: open its \(saved.clipCount) saved clip\(saved.clipCount == 1 ? "" : "s")",
                                      systemImage: "film.stack")
                                    .font(.subheadline)
                            }
                        }
                        Button(role: .destructive) {
                            self.selected = nil
                        } label: {
                            Label("Choose a different video", systemImage: "xmark.circle").font(.subheadline)
                        }
                    }
                } else {
                    Group {
                        if mode == .manual {
                            PhotosPicker(selection: $manualPicks, maxSelectionCount: 10, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                                buttonLabel(loading ? "Opening…" : "Choose video or photos", icon: "photo.on.rectangle.angled")
                            }
                        } else {
                            PhotosPicker(selection: $pick, matching: .videos, photoLibrary: .shared()) {
                                buttonLabel(loading ? "Opening video…" : "Choose footage", icon: "video.badge.plus")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }
                if loading { ProgressView() }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if !store.projects.isEmpty { savedList }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 40)
          }
            .navigationTitle("Clips")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $footage) { f in ProjectView(url: f.url, useClaude: f.useClaude, assetID: f.assetID) }
            .navigationDestination(item: $openSaved) { o in ProjectView(saved: o.project, url: o.url) }
            .confirmationDialog("Remove this video's clips?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { p in
                Button("Remove", role: .destructive) { store.delete(p.id) }
            } message: { _ in
                Text("The video stays in Photos and anything already scheduled stays on your calendar.")
            }
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

    /// Videos you've already found clips in.
    private var savedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your footage").font(.headline).padding(.top, 8)
            ForEach(store.projects) { p in
                Button { openSaved = OpenSaved(project: p) } label: { savedRow(p) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmDelete = p }
                    }
            }
            Text("Touch and hold a video to remove it.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedRow(_ p: SavedProject) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = store.thumbnail(for: p.id) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 72)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(p.name) · \(timecode(p.duration))").font(.subheadline.weight(.semibold))
                Text(summary(p)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func summary(_ p: SavedProject) -> String {
        var parts = ["\(p.clipCount) clip\(p.clipCount == 1 ? "" : "s")"]
        let waiting = max(0, p.keptCount - p.scheduledCount)
        if waiting > 0 { parts.append("\(waiting) kept, not scheduled") }
        if p.scheduledCount > 0 { parts.append("\(p.scheduledCount) scheduled") }
        return parts.joined(separator: " · ")
    }

    private func buttonLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
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
            // Show it in the preview first; scanning starts when you tap Find clips.
            selected = Footage(url: movie.url, useClaude: false, assetID: item.itemIdentifier)
        } catch {
            self.error = "Couldn't open that video: \(error.localizedDescription)"
        }
    }

    /// Manual: one video goes in the preview (then "Edit this video"); photos open the photo screen;
    /// a mix of several videos/photos is posted as is.
    private func loadManual(_ picks: [PhotosPickerItem]) async {
        loading = true
        error = nil
        defer { loading = false; manualPicks = [] }
        do {
            let imported = try await ManualImport.load(picks)
            let videos = imported.items.filter(\.isVideo)
            if imported.items.count == 1, let v = videos.first, let url = v.videoURL {
                selected = Footage(url: url, useClaude: false, assetID: v.assetID)
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
