import AVKit
import SwiftUI

/// Plays one stretch of a video on a loop.
@MainActor
final class LoopingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    private var start: Double = 0
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    func load(url: URL, start: Double, end: Double) {
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        if statusObserver == nil {
            statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
                let playing = p.timeControlStatus != .paused
                Task { @MainActor in self?.isPlaying = playing }
            }
        }
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
                Task { @MainActor in self?.currentTime = t.seconds }
            }
        }
        if endObserver == nil {
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                    self.restart()
                }
            }
        }
        setRange(start: start, end: end)
    }

    func setRange(start: Double, end: Double) {
        self.start = start
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        restart()
    }

    /// Jump close to the end, to hear how the clip lands.
    func previewEnding(end: Double) {
        player.seek(to: CMTime(seconds: max(start, end - 4), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// Move the playhead to any point (from touching the waveform) and keep playing.
    func seek(to t: Double) {
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func restart() {
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func pause() { player.pause() }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    deinit {
        statusObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}

struct ClipEditorView: View {
    @Binding var clip: ClipSuggestion
    let analysis: VideoAnalysis
    /// When set, the editor saves back to an existing scheduled post instead of offering Schedule.
    var onSaveToPost: ((URL, ClipSuggestion) async throws -> Void)? = nil

    @StateObject private var looper = LoopingPlayer()
    @State private var savingToPost = false
    @State private var savedToPost = false
    @State private var rendering = false
    @State private var renderProgress = 0.0
    @State private var message: String?
    @State private var saved = false

    @State private var showSchedule = false
    @State private var hashtagText = ""
    @State private var youtubeTagText = ""

    /// The finished file, kept on the clip so scheduling can reuse it.
    private var output: URL? {
        get { clip.renderedURL }
        nonmutating set {
            clip.renderedURL = newValue
            if newValue == nil { savedToPost = false }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(timecode(clip.start, tenths: true)) – \(timecode(clip.end, tenths: true))")
                        .font(.headline.monospacedDigit())
                    Spacer()
                    Text(String(format: "%.1f s", clip.length))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(clip.length > 90 ? .orange : .secondary)
                }

                FramedPreview(player: looper.player, source: analysis.sourceSize, framing: framingBinding,
                              text: clip.onScreenText, showText: showsTextNow, onTap: { looper.togglePlay() })
                    .frame(maxHeight: 460)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        // A big play button whenever it's paused.
                        if !looper.isPlaying {
                            Button { looper.togglePlay() } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 72, height: 72)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play")
                        }
                    }

                framingControls

                if !clip.why.isEmpty {
                    Text(clip.why).font(.subheadline).foregroundStyle(.secondary)
                }

                WaveformStrip(analysis: analysis, start: clip.start, end: clip.end, playhead: looper.currentTime) { t in
                    looper.seek(to: min(t, clip.end - 0.1))
                }
                .frame(height: 90)

                HStack(spacing: 10) {
                    Button { looper.togglePlay() } label: {
                        Label(looper.isPlaying ? "Pause" : "Play", systemImage: looper.isPlaying ? "pause.fill" : "play.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: 22)
                    }
                    .accessibilityLabel(looper.isPlaying ? "Pause" : "Play")
                    Button { looper.restart() } label: { Label("Hear the start", systemImage: "backward.end.fill") }
                    Button { looper.previewEnding(end: clip.end) } label: { Label("Hear the ending", systemImage: "forward.end.fill") }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)

                trimRow(label: "Start", value: $clip.start, isStart: true)
                trimRow(label: "End", value: $clip.end, isStart: false)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Title for your calendar", text: $clip.title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("On-screen text").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Leave empty for no text", text: $clip.onScreenText)
                        .textFieldStyle(.roundedBorder)
                    Text("Shows near the top for the first \(Int(ClipRenderer.textSeconds)) seconds.").font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill").foregroundStyle(Theme.accent)
                        Text("Instagram caption").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy caption") { UIPasteboard.general.string = clip.fullCaption; message = "Caption copied." }
                            .font(.footnote)
                    }
                    CaptionEditor(text: $clip.caption, minHeight: 90)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    if clip.caption.contains("[") {
                        Text("Fill in the [brackets] before posting.").font(.caption).foregroundStyle(.orange)
                    }
                }

                HashtagField(text: $hashtagText)
                    .onAppear { hashtagText = DefaultHashtags.format(clip.hashtags) }
                    .onChange(of: hashtagText) { _, t in clip.hashtags = DefaultHashtags.parse(t) }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                        Text("YouTube title").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Instagram caption") {
                            let t = DefaultHashtags.youtubeTitle(fromCaption: clip.caption)
                            clip.youtubeTitle = t.isEmpty ? nil : t
                        }
                        .font(.footnote)
                        .tint(.red)
                        .disabled(clip.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextField(clip.title.isEmpty ? "Title for the Short" : clip.title,
                              text: Binding(get: { clip.youtubeTitle ?? "" },
                                            set: { clip.youtubeTitle = $0.isEmpty ? nil : String($0.prefix(100)) }),
                              axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty to use the title above. The hashtags below go at the end of it.")
                        .font(.caption).foregroundStyle(.secondary)
                    HashtagField(text: $youtubeTagText, label: "YouTube hashtags")
                        .onAppear { youtubeTagText = DefaultHashtags.format(clip.youtubeHashtags ?? clip.hashtags) }
                        .onChange(of: youtubeTagText) { _, t in
                            let tags = DefaultHashtags.parse(t)
                            clip.youtubeHashtags = tags == clip.hashtags ? nil : tags
                        }
                        .onChange(of: clip.hashtags) { _, tags in
                            // Follow Instagram's hashtags until they're changed here.
                            if clip.youtubeHashtags == nil { youtubeTagText = DefaultHashtags.format(tags) }
                        }
                    Text("Copied from Instagram's hashtags. Change them here to use different ones on YouTube.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if onSaveToPost == nil {
                    CarouselEditor(items: Binding(get: { clip.carousel },
                                                  set: { clip.extras = $0.isEmpty ? nil : $0 }))
                }

                Toggle("Keep this clip", isOn: $clip.keep)

                exportSection

                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(clip.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { looper.load(url: analysis.url, start: clip.start, end: clip.end) }
        .onDisappear { looper.pause() }
        .onChange(of: clip.start) { _, _ in rangeChanged() }
        .onChange(of: clip.end) { _, _ in rangeChanged() }
        .onChange(of: clip.onScreenText) { _, _ in output = nil; saved = false }
        .sheet(isPresented: $showSchedule) { ScheduleSheet(clip: $clip, analysis: analysis) }
    }

    /// The clip's framing, set up automatically the first time.
    private var framingBinding: Binding<Framing> {
        Binding(
            get: { clip.framing ?? Framing.automatic(for: analysis.sourceSize) },
            set: { clip.framing = $0; output = nil; saved = false }
        )
    }

    private var showsTextNow: Bool {
        let t = looper.currentTime - clip.start
        return t >= 0.3 && t <= ClipRenderer.textSeconds
    }

    private var framingControls: some View {
        let f = framingBinding.wrappedValue
        let source = analysis.sourceSize
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Whole picture") { framingBinding.wrappedValue = Framing(zoom: 1) }
                    .buttonStyle(.bordered)
                    .tint(f.zoom <= 1.001 ? Theme.accent : .secondary)
                Button("Fill frame") { framingBinding.wrappedValue = Framing(zoom: Framing.fillZoom(source)).clamped(for: source) }
                    .buttonStyle(.bordered)
                    .tint(abs(f.zoom - Framing.fillZoom(source)) < 0.01 && f.offsetX == 0 && f.offsetY == 0 ? Theme.accent : .secondary)
                Spacer()
                Text(f.zoom <= 1.001 ? "No crop" : String(format: "Zoom %.1f×", f.zoom))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Text(f.crops(source)
                 ? "Edges are cut off. Pinch to zoom out or drag to move. The export matches this preview."
                 : "Pinch to zoom, drag to move, tap to pause. The export matches this preview.")
                .font(.caption)
                .foregroundStyle(f.crops(source) ? .orange : .secondary)
        }
    }

    private func rangeChanged() {
        output = nil
        saved = false
        looper.setRange(start: clip.start, end: clip.end)
    }

    @ViewBuilder
    private var exportSection: some View {
        if let when = clip.scheduledFor {
            Label("Scheduled for \(when.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))",
                  systemImage: "calendar.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        if let onSaveToPost, !rendering {
            Button {
                Task { await saveToPost(onSaveToPost) }
            } label: {
                Label(savingToPost ? "Saving…" : savedToPost ? "Saved to the post" : "Save changes to this post",
                      systemImage: savedToPost ? "checkmark" : "square.and.arrow.up.on.square")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(savingToPost || savedToPost)
        } else if !rendering {
            Button {
                looper.pause()
                showSchedule = true
            } label: {
                Label(clip.scheduledFor == nil ? "Schedule your post…" : "Schedule again…", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        if rendering {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: renderProgress)
                Text("Making the clip…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if let output {
            VStack(spacing: 10) {
                Button {
                    Task {
                        do {
                            try await ClipRenderer.saveToPhotos(output)
                            saved = true
                            message = "Saved to Photos. The caption is ready to paste."
                            UIPasteboard.general.string = clip.fullCaption
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                } label: {
                    Label(saved ? "Saved to Photos" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(saved)
                ShareLink(item: output) {
                    Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                Task { await render() }
            } label: {
                Label("Make clip to save or share", systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func saveToPost(_ save: (URL, ClipSuggestion) async throws -> Void) async {
        savingToPost = true
        defer { savingToPost = false }
        if output == nil || !FileManager.default.fileExists(atPath: output!.path) { await render() }
        guard let file = output else { return }
        do {
            message = "Uploading the new version…"
            try await save(file, clip)
            savedToPost = true
            message = "Saved. The new version replaces the scheduled one."
        } catch {
            message = error.localizedDescription
        }
    }

    private func render() async {
        rendering = true
        renderProgress = 0
        message = nil
        looper.pause()
        defer { rendering = false }
        do {
            output = try await ClipRenderer.render(source: analysis.url, start: clip.start, end: clip.end, text: clip.onScreenText,
                                                   framing: framingBinding.wrappedValue) { p in
                Task { @MainActor in renderProgress = p }
            }
            clip.keep = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func trimRow(label: String, value: Binding<Double>, isStart: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(timecode(value.wrappedValue, tenths: true)).font(.body.monospacedDigit().weight(.semibold))
            }
            .frame(width: 70, alignment: .leading)
            Spacer()
            Button { step(value, to: previousBreath(before: value.wrappedValue), isStart: isStart) } label: {
                Image(systemName: "backward.end")
            }
            .accessibilityLabel("Previous breath")
            Button("−0.5") { step(value, to: value.wrappedValue - 0.5, isStart: isStart) }
            Button("+0.5") { step(value, to: value.wrappedValue + 0.5, isStart: isStart) }
            Button { step(value, to: nextBreath(after: value.wrappedValue), isStart: isStart) } label: {
                Image(systemName: "forward.end")
            }
            .accessibilityLabel("Next breath")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func step(_ value: Binding<Double>, to t: Double?, isStart: Bool) {
        guard let t else { return }
        if isStart {
            value.wrappedValue = min(max(0, t), clip.end - 5)
        } else {
            value.wrappedValue = max(min(analysis.duration, t), clip.start + 5)
        }
    }

    private func previousBreath(before t: Double) -> Double? { analysis.breaths.last { $0 < t - 0.2 } }
    private func nextBreath(after t: Double) -> Double? { analysis.breaths.first { $0 > t + 0.2 } }
}

/// The loudness around the clip, with the clip highlighted, phrase breaths marked and a moving playhead.
/// Touch or drag on it to move the playhead.
struct WaveformStrip: View {
    let analysis: VideoAnalysis
    let start: Double
    let end: Double
    var playhead: Double? = nil
    var onSeek: ((Double) -> Void)? = nil

    /// The stretch of time the strip shows: the clip plus some context on each side.
    private var window: (lo: Double, hi: Double) {
        let pad = max(8, (end - start) * 0.35)
        return (max(0, start - pad), min(analysis.duration, end + pad))
    }

    var body: some View {
        VStack(spacing: 2) {
            labels
            strip.accessibilityLabel(accessibilityText)
        }
    }

    /// Start and end times over their markers, and the clip's length in the middle.
    private var labels: some View {
        GeometryReader { geo in
            let (lo, hi) = window
            let w = geo.size.width
            let x = { (t: Double) -> CGFloat in hi > lo ? CGFloat((t - lo) / (hi - lo)) * w : 0 }
            ZStack {
                Text(String(format: "%.1f s", end - start))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .position(x: w / 2, y: 8)
                Text(timecode(start, tenths: true))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .position(x: min(max(x(start), 24), w - 24), y: 8)
                Text(timecode(end, tenths: true))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .position(x: min(max(x(end), 24), w - 24), y: 8)
            }
        }
        .frame(height: 16)
    }

    private var strip: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let (lo, hi) = window
                guard hi > lo, !analysis.waveform.isEmpty else { return }
                let wave = analysis.waveform
                let x = { (t: Double) -> CGFloat in CGFloat((t - lo) / (hi - lo)) * size.width }

                ctx.fill(Path(CGRect(x: x(start), y: 0, width: x(end) - x(start), height: size.height)),
                         with: .color(Theme.accent.opacity(0.18)))

                let bars = Int(size.width / 3)
                for b in 0..<bars {
                    let t = lo + (hi - lo) * Double(b) / Double(bars)
                    let i = min(wave.count - 1, max(0, Int(t / analysis.hop)))
                    let h = CGFloat(wave[i]) * size.height * 0.9 + 2
                    let inside = t >= start && t <= end
                    ctx.fill(Path(CGRect(x: CGFloat(b) * 3, y: (size.height - h) / 2, width: 2, height: h)),
                             with: .color(inside ? Theme.accent : .secondary.opacity(0.5)))
                }
                for br in analysis.breaths where br >= lo && br <= hi {
                    ctx.fill(Path(CGRect(x: x(br) - 0.5, y: size.height - 6, width: 1, height: 6)), with: .color(.primary.opacity(0.6)))
                }
                for edge in [start, end] {
                    ctx.fill(Path(CGRect(x: x(edge) - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
                }
                if let p = playhead, p >= lo, p <= hi {
                    let px = x(p)
                    ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
                    ctx.fill(Path(ellipseIn: CGRect(x: px - 5, y: -1, width: 10, height: 10)), with: .color(.primary))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let onSeek, geo.size.width > 0 else { return }
                        let (lo, hi) = window
                        let f = min(1, max(0, g.location.x / geo.size.width))
                        onSeek(lo + (hi - lo) * Double(f))
                    }
            )
        }
    }

    private var accessibilityText: String {
        "Waveform from \(timecode(start)) to \(timecode(end)). Small ticks mark phrase breaths. Touch to move the playhead."
    }
}
