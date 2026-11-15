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
    var id: URL { url }
}

struct HomeView: View {
    @EnvironmentObject var session: SessionStore
    @State private var pick: PhotosPickerItem?
    @State private var footage: Footage?
    @State private var loading = false
    @State private var error: String?
    @State private var showSettings = false
    @AppStorage("useClaude") private var useClaude = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "film.stack")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(spacing: 8) {
                    Text("Find clips in your footage")
                        .font(.title2.weight(.semibold))
                    Text("Pick a concert or practice video. Claude listens for the phrases, watches the shots, and suggests the best 20–40 second moments.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick clips with").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Pick clips with", selection: $useClaude) {
                        Text("Claude").tag(true)
                        Text("On-device only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text(useClaude
                         ? "Claude looks at frames and the audio map. Uses one Claude request."
                         : "Picks the busiest stretches from the audio alone. Free, works offline, less musical.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $pick, matching: .videos, photoLibrary: .shared()) {
                    Label(loading ? "Opening video…" : "Choose footage", systemImage: "video.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(item: $footage) { f in ProjectView(url: f.url, useClaude: f.useClaude) }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .task { await session.refreshProfile() }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        loading = true
        error = nil
        defer { loading = false; pick = nil }
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                error = "Couldn't open that video. If it's in iCloud, open it in Photos once so it downloads, then try again."
                return
            }
            footage = Footage(url: movie.url, useClaude: useClaude)
        } catch {
            self.error = "Couldn't open that video: \(error.localizedDescription)"
        }
    }
}
