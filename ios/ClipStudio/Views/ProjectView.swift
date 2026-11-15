import SwiftUI

@MainActor
final class ProjectModel: ObservableObject {
    enum Phase: Equatable { case analyzing, suggesting, ready, failed(String) }

    let url: URL
    let useClaude: Bool
    @Published var phase: Phase = .analyzing
    @Published var progress: Double = 0
    @Published var progressLabel = "Getting ready…"
    @Published var analysis: VideoAnalysis?
    @Published var clips: [ClipSuggestion] = []
    @Published var note: String?

    init(url: URL, useClaude: Bool) {
        self.url = url
        self.useClaude = useClaude
    }

    func start() async {
        guard analysis == nil else { return }
        phase = .analyzing
        do {
            let a = try await VideoAnalyzer.analyze(url: url) { [weak self] p, label in
                Task { @MainActor in
                    self?.progress = p
                    self?.progressLabel = label
                }
            }
            analysis = a
            if useClaude { await suggest() } else { onDevice() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func onDevice() {
        guard let a = analysis else { return }
        clips = ClipSuggester.fallback(a)
        note = clips.isEmpty ? "No clear phrases found. Try Claude, or a longer video." : "Picked from the audio alone, on your phone."
        phase = .ready
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
    }
}

struct ProjectView: View {
    @StateObject private var model: ProjectModel
    @State private var showBatch = false

    init(url: URL, useClaude: Bool) {
        _model = StateObject(wrappedValue: ProjectModel(url: url, useClaude: useClaude))
    }

    var body: some View {
        Group {
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
                    if let note = model.note { Text(note).foregroundStyle(model.useClaude ? .orange : .secondary) }
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
