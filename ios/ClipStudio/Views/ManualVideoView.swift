import SwiftUI

/// Manual mode with one video: the whole video is the clip, with no zoom.
/// Opens straight into the editor so you can still trim, frame, caption and schedule.
struct ManualVideoView: View {
    let url: URL
    let assetID: String?

    @State private var analysis: VideoAnalysis?
    @State private var clip = ClipSuggestion(start: 0, end: 1, title: "", why: "", onScreenText: "", caption: "", hashtags: [])
    @State private var status = "Opening the video…"
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        ZStack {  // a real container, so .task below runs once
            if let analysis {
                ClipEditorView(clip: $clip, analysis: analysis)
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't open this video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else {
                VStack(spacing: 14) {
                    if let progress { ProgressView(value: progress).frame(maxWidth: 240) } else { ProgressView() }
                    Text(status).font(.headline)
                    Text("Reading the audio for the waveform. Everything happens on your phone.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle("Manual")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard analysis == nil, failure == nil else { return }
            do {
                var a = try await VideoAnalyzer.analyze(url: url, minimumDuration: 3, requireAudio: false) { p, label in
                    Task { @MainActor in progress = p; status = label }
                }
                a.sourceAssetID = assetID
                var whole = ClipSuggestion(start: 0, end: a.duration, title: "", why: "", onScreenText: "", caption: "", hashtags: [])
                whole.framing = Framing(zoom: 1)   // no zoom: the whole picture
                whole.fromClaude = false
                whole.keep = true
                clip = whole
                analysis = a
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
