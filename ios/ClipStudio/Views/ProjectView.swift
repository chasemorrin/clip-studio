import SwiftUI

@MainActor
final class ProjectModel: ObservableObject {
    enum Phase: Equatable { case analyzing, suggesting, ready, failed(String) }

    let url: URL
    @Published var phase: Phase = .analyzing
    @Published var progress: Double = 0
    @Published var progressLabel = "Getting ready…"
    @Published var analysis: VideoAnalysis?
    @Published var clips: [ClipSuggestion] = []
    @Published var note: String?

    init(url: URL) { self.url = url }

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
            await suggest()
        } catch {
            phase = .failed(error.localizedDescription)
        }
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

    init(url: URL) {
        _model = StateObject(wrappedValue: ProjectModel(url: url))
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
                    if let note = model.note { Text(note).foregroundStyle(.orange) }
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
                Section {
                    Button {
                        Task { await model.suggest() }
                    } label: {
                        Label("Ask Claude for different clips", systemImage: "arrow.clockwise")
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
                if clip.keep { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
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
