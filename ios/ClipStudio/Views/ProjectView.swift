import SwiftUI

@MainActor
final class ProjectModel: ObservableObject {
    enum Phase: Equatable { case analyzing, suggesting, ready, failed(String) }

    private(set) var url: URL?
    let useClaude: Bool
    let assetID: String?
    /// Saved projects keep their clips between visits (only videos from the photo library can be reopened).
    let projectID: UUID
    private let saved: SavedProject?
    @Published var phase: Phase = .analyzing
    @Published var progress: Double = 0
    @Published var progressLabel = "Getting ready…"
    @Published var analysis: VideoAnalysis?
    @Published var clips: [ClipSuggestion] = []
    @Published var note: String?

    init(url: URL, useClaude: Bool, assetID: String?) {
        self.url = url
        self.useClaude = useClaude
        self.assetID = assetID
        projectID = UUID()
        saved = nil
    }

    /// Reopens a saved project. Pass the video's file if it's already at hand; otherwise it's loaded from Photos.
    init(saved: SavedProject, url: URL? = nil) {
        self.url = url
        useClaude = saved.useClaude
        assetID = saved.assetID
        projectID = saved.id
        self.saved = saved
    }

    var canSave: Bool { assetID != nil }

    func start() async {
        guard analysis == nil else { return }
        phase = .analyzing
        if let saved { return await reopen(saved) }
        guard let url else { return }
        do {
            var a = try await VideoAnalyzer.analyze(url: url) { [weak self] p, label in
                Task { @MainActor in
                    self?.progress = p
                    self?.progressLabel = label
                }
            }
            a.sourceAssetID = assetID
            analysis = a
            if useClaude { await suggest() } else { onDevice() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func reopen(_ saved: SavedProject) async {
        progressLabel = "Opening the video…"
        progress = 0
        do {
            let file: URL
            if let url { file = url } else { file = try await SourceVideo.load(assetId: saved.assetID) }
            url = file
            if let a = ProjectStore.shared.analysis(for: saved, url: file) {
                analysis = a
            } else {
                var a = try await VideoAnalyzer.analyze(url: file) { [weak self] p, label in
                    Task { @MainActor in
                        self?.progress = p
                        self?.progressLabel = label
                    }
                }
                a.sourceAssetID = saved.assetID
                analysis = a
            }
            clips = ProjectStore.shared.clips(for: saved.id) ?? []
            note = saved.note
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Saves the clips (and their keep / scheduled marks) so they're there next time.
    func persist() {
        guard phase == .ready, let a = analysis, let assetID else { return }
        ProjectStore.shared.save(id: projectID, assetID: assetID, useClaude: useClaude, analysis: a, clips: clips, note: note)
    }

    func onDevice() {
        guard let a = analysis else { return }
        clips = ClipSuggester.fallback(a)
        note = clips.isEmpty ? "No clear phrases found. Try Claude, or a longer video." : "Picked from the audio alone, on your phone."
        phase = .ready
        persist()
    }

    func suggest() async {
        guard let a = analysis else { return }
        phase = .suggesting
        note = nil
        do {
            clips = try await ClipSuggester.suggest(a)
        } catch {
            clips = ClipSuggester.fallback(a)
            note = "Claude couldn't pick clips (\(error.localizedDescription)) These picks come from the audio alone."
        }
        phase = .ready
        persist()
    }
}

struct ProjectView: View {
    @StateObject private var model: ProjectModel
    @State private var showBatch = false

    init(url: URL, useClaude: Bool, assetID: String? = nil) {
        _model = StateObject(wrappedValue: ProjectModel(url: url, useClaude: useClaude, assetID: assetID))
    }

    init(saved: SavedProject, url: URL? = nil) {
        _model = StateObject(wrappedValue: ProjectModel(saved: saved, url: url))
    }

    var body: some View {
        ZStack {  // a real container, so .task below runs once instead of restarting whenever the content switches
            switch model.phase {
            case .analyzing:
                working(title: model.progressLabel, detail: "Everything here happens on your phone.", progress: model.progress)
            case .suggesting:
                working(title: "Claude is picking clips…", detail: "This usually takes 20–60 seconds.", progress: nil)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read this video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .ready:
                list
            }
        }
        .navigationTitle("Suggested clips")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
        .onChange(of: model.clips) { _, _ in model.persist() }
        .sheet(isPresented: $showBatch) {
            if let a = model.analysis { BatchScheduleSheet(model: model, analysis: a) }
        }
    }

    private func working(title: String, detail: String, progress: Double?) -> some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 240)
            } else {
                ProgressView()
            }
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var list: some View {
        List {
            if let a = model.analysis {
                Section {
                    LabeledContent("Length", value: timecode(a.duration))
                    LabeledContent("Camera shots", value: "\(a.sections.count)")
                    LabeledContent("Phrase breaths found", value: "\(a.breaths.count)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let note = model.note { Text(note).foregroundStyle(model.useClaude ? .orange : .secondary) }
                        if model.canSave {
                            Text("Saved in the Clips tab, so you can come back to these clips anytime.")
                        } else {
                            Text("This video didn't come from your photo library, so these clips can't be saved for later.")
                        }
                    }
                }
                Section("Tap a clip to watch, adjust and export it") {
                    ForEach($model.clips) { $clip in
                        NavigationLink {
                            ClipEditorView(clip: $clip, analysis: a)
                        } label: {
                            ClipRow(clip: clip)
                        }
                    }
                }
                let keptCount = model.clips.filter { $0.keep && $0.scheduledFor == nil }.count
                Section {
                    Button {
                        showBatch = true
                    } label: {
                        Label(keptCount == 0 ? "Schedule kept clips" : "Schedule \(keptCount) kept clip\(keptCount == 1 ? "" : "s")…",
                              systemImage: "calendar.badge.plus")
                    }
                    .disabled(keptCount == 0)
                } footer: {
                    Text("Turn on \"Keep this clip\" in each clip you like, then schedule them all at once into your next open posting days.")
                }
                Section {
                    Button {
                        Task { await model.suggest() }
                    } label: {
                        Label(model.clips.contains(where: { $0.fromClaude }) ? "Ask Claude for different clips" : "Ask Claude to pick clips",
                              systemImage: "sparkles")
                    }
                    Button {
                        model.onDevice()
                    } label: {
                        Label("Use on-device picks", systemImage: "waveform")
                    }
                }
            }
        }
    }
}

struct ClipRow: View {
    let clip: ClipSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(clip.title).font(.headline)
                Spacer()
                if clip.scheduledFor != nil {
                    Image(systemName: "calendar.badge.checkmark").foregroundStyle(Theme.accent)
                } else if clip.keep {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            }
            Text("\(timecode(clip.start))–\(timecode(clip.end)) · \(Int(clip.length.rounded()))s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !clip.why.isEmpty {
                Text(clip.why).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}
