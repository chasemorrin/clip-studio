import SwiftUI

private let whenFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()

/// Schedule one clip: makes it (if needed), uploads it and puts it on the calendar.
struct ScheduleSheet: View {
    @Binding var clip: ClipSuggestion
    let analysis: VideoAnalysis

    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date().addingTimeInterval(3600)
    @State private var nextSlot: Date?
    @State private var autoPost = true
    @State private var youtube = false
    @State private var youtubeTitle = ""
    @State private var pushBack = false
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?

    private var instagramConnected: Bool { session.instagramUsername != nil }
    private var toYouTube: Bool { youtube && session.youtubeChannel != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(clip.title, value: String(format: "%.0f s", clip.length))
                }
                Section {
                    DatePicker("Post on", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    if let nextSlot, abs(nextSlot.timeIntervalSince(when)) > 60 {
                        Button("Use next open slot: \(nextSlot.formatted(whenFormat))") { when = nextSlot }
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("Starts at your next open posting day. Change your posting days and time in Settings.")
                }
                PushBackSection(day: when, isOn: $pushBack)
                Section {
                    Toggle("Post to Instagram automatically", isOn: $autoPost)
                        .disabled(!instagramConnected)
                } footer: {
                    Text(instagramConnected
                         ? "It posts within 5 minutes of the time you pick. You can change or cancel it in Calendar."
                         : "Connect Instagram in Settings to post automatically. Until then it goes on your calendar as a reminder.")
                }
                YouTubeOptionsSection(isOn: $youtube, title: $youtubeTitle)
                if instagramConnected || toYouTube {
                    Section {
                        Button {
                            Task { await schedule(postNow: true) }
                        } label: {
                            Label(postNowLabel, systemImage: "paperplane.fill")
                        }
                        .disabled(working != nil)
                    } footer: {
                        Text("Skips the calendar time. Usually live within 1–3 minutes.")
                    }
                }
                Section("Caption") {
                    Text(clip.fullCaption).font(.callout)
                    if clip.caption.contains("[") {
                        Text("Fill in the [brackets] before it posts.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let working {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            if let progress { ProgressView(value: progress) } else { ProgressView() }
                            Text(working).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Schedule clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { Task { await schedule() } }.disabled(working != nil)
                }
            }
            .interactiveDismissDisabled(working != nil)
            .task {
                await posts.refresh()
                nextSlot = PostingSchedule.nextSlots(1, taken: posts.takenDays).first
                if let nextSlot { when = nextSlot }
                autoPost = instagramConnected
                youtube = session.youtubeByDefault
                if youtubeTitle.isEmpty { youtubeTitle = clip.title }
            }
        }
    }

    private var postNowLabel: String {
        switch (instagramConnected, toYouTube) {
        case (true, true): return "Post to Instagram and YouTube now"
        case (false, true): return "Post to YouTube now"
        default: return "Post to Instagram now"
        }
    }

    private func schedule(postNow: Bool = false) async {
        error = nil
        do {
            let file: URL
            if let done = clip.renderedURL, FileManager.default.fileExists(atPath: done.path) {
                file = done
            } else {
                working = "Making the clip…"
                progress = 0
                file = try await ClipRenderer.render(clip: clip, analysis: analysis) { p in
                    Task { @MainActor in progress = p }
                }
                clip.renderedURL = file
            }
            working = "Uploading…"
            progress = nil
            let at = postNow ? Date() : when
            let id = try await posts.schedule(file: file, clip: clip, at: at, autoPost: instagramConnected && (postNow || autoPost),
                                              youtube: toYouTube, youtubeTitle: youtubeTitle, sourceAssetID: analysis.sourceAssetID)
            if postNow {
                working = toYouTube ? "Sending…" : "Sending to Instagram…"
                try await posts.postNow(id: id, instagram: instagramConnected, youtube: toYouTube)
            } else if pushBack {
                working = "Moving the other posts back…"
                await posts.pushBackAfterScheduling(true, day: at, newID: id)
            }
            clip.scheduledFor = at
            clip.keep = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
            working = nil
        }
    }
}

/// The "also post to YouTube" switch and the Short's title.
struct YouTubeOptionsSection: View {
    @Binding var isOn: Bool
    @Binding var title: String
    /// Shown under the switch, e.g. the post's YouTube status in the Calendar.
    var status: Post.YouTubeStatus? = nil
    var locked = false
    @EnvironmentObject var session: SessionStore

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                Label("Post to YouTube Shorts", systemImage: "play.rectangle")
            }
            .disabled(session.youtubeChannel == nil || locked)
            if isOn {
                TextField("YouTube title", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                    .disabled(locked)
                    .onChange(of: title) { _, v in if v.count > 100 { title = String(v.prefix(100)) } }
            }
            if let status, status.isOn {
                YouTubeStatusView(status: status)
            }
        } header: {
            Text("YouTube")
        } footer: {
            if session.youtubeChannel == nil {
                Text("Connect YouTube in Settings to post Shorts too.")
            } else if isOn {
                Text("Same time and caption as Instagram. Titles can be up to 100 characters (\(title.count) now).")
            }
        }
    }
}

/// A post's YouTube status: where it is, any error, and a link once it's up.
struct YouTubeStatusView: View {
    let status: Post.YouTubeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Status").foregroundStyle(.secondary)
                Spacer()
                YouTubePill(status: status)
            }
            if let e = status.error {
                Text(e).font(.footnote).foregroundStyle(status.state == .failed ? Color.red : Color.orange)
            }
            if status.state == .posted, status.privacy == "private" {
                Text("YouTube kept it private (Clip Studio isn't approved by Google yet). Make it public in the YouTube app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let url = status.url {
                Link("Open on YouTube", destination: url).font(.footnote)
            }
        }
    }
}

struct YouTubePill: View {
    let status: Post.YouTubeStatus

    var body: some View {
        let (text, color): (String, Color) = {
            switch status.state {
            case .off: return ("Off", .gray)
            case .scheduled: return ("Scheduled", .red)
            case .uploading: return ("Uploading…", .blue)
            case .posted: return status.privacy == "private" ? ("Private", Color.orange) : ("Posted", Color.green)
            case .failed: return ("Failed", .red)
            }
        }()
        HStack(spacing: 3) {
            Image(systemName: "play.rectangle.fill").font(.caption2)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Shown when the chosen day already has a post: lists it and offers to push it (and any post
/// in the way) back to the next open posting slot.
struct PushBackSection: View {
    let day: Date
    var excluding: String? = nil
    @Binding var isOn: Bool
    /// True outside a Form: draws the same rows in a plain stack.
    var plain = false
    @EnvironmentObject var posts: PostsStore

    var body: some View {
        let others = posts.conflicts(on: day, excluding: excluding)
        if !others.isEmpty {
            if plain {
                VStack(alignment: .leading, spacing: 8) {
                    header(others.count).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    rows(others)
                    footer.font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Section {
                    rows(others)
                } header: {
                    header(others.count)
                } footer: {
                    footer
                }
            }
        }
    }

    private func header(_ count: Int) -> Text {
        Text(count == 1 ? "Already scheduled this day" : "\(count) already scheduled this day")
    }

    private var footer: Text {
        Text(isOn
             ? "Each moves to your next open posting slot, and any post in the way moves along too."
             : "Turn on to give this day to this post and move the others later.")
    }

    @ViewBuilder
    private func rows(_ others: [Post]) -> some View {
        ForEach(others) { p in
            LabeledContent(p.title.isEmpty ? "Untitled" : p.title,
                           value: p.publishAt?.formatted(date: .omitted, time: .shortened) ?? "")
        }
        Toggle("Push scheduled posts back", isOn: $isOn)
        if isOn {
            ForEach(posts.pushBackPlan(from: day, excluding: excluding)) { m in
                HStack {
                    Text(m.post.title.isEmpty ? "Untitled" : m.post.title).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(m.to.formatted(whenFormat)).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }
}

/// Schedule every kept clip at once, one per open posting slot.
struct BatchScheduleSheet: View {
    @ObservedObject var model: ProjectModel
    let analysis: VideoAnalysis

    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var times: [UUID: Date] = [:]
    @State private var autoPost = true
    @State private var youtube = false
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var done = 0

    private var pending: [ClipSuggestion] { model.clips.filter { $0.keep && $0.scheduledFor == nil } }
    private var instagramConnected: Bool { session.instagramUsername != nil }

    var body: some View {
        NavigationStack {
            Form {
                if pending.isEmpty {
                    Section {
                        Text(done > 0 ? "All \(done) clips are scheduled." : "Turn on \"Keep this clip\" for the clips you want, then come back here.")
                    }
                } else {
                    Section {
                        ForEach(pending) { c in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(c.title).font(.headline)
                                    Spacer()
                                    Text(String(format: "%.0f s", c.length)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                DatePicker("Post on", selection: time(for: c.id), in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                    .font(.subheadline)
                                if c.caption.contains("[") {
                                    Text("Caption still has [brackets] to fill in.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("\(pending.count) kept clips")
                    } footer: {
                        Text("Each clip gets its own open posting day. Change your posting days and time in Settings.")
                    }
                    Section {
                        Toggle("Post to Instagram automatically", isOn: $autoPost).disabled(!instagramConnected)
                        Toggle("Post to YouTube Shorts too", isOn: $youtube).disabled(session.youtubeChannel == nil)
                    } footer: {
                        if !instagramConnected { Text("Connect Instagram in Settings to post automatically.") }
                        else if session.youtubeChannel == nil { Text("Connect YouTube in Settings to post Shorts too.") }
                        else if youtube { Text("Each Short uses the clip's title. You can change it per post in Calendar.") }
                    }
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
            .navigationTitle("Schedule clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(pending.isEmpty ? "Done" : "Cancel") { dismiss() }.disabled(working != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule \(pending.count)") { Task { await run() } }
                        .disabled(working != nil || pending.isEmpty)
                }
            }
            .interactiveDismissDisabled(working != nil)
            .task {
                await posts.refresh()
                let slots = PostingSchedule.nextSlots(pending.count, taken: posts.takenDays)
                for (c, slot) in zip(pending, slots) { times[c.id] = slot }
                autoPost = instagramConnected
                youtube = session.youtubeByDefault
            }
        }
    }

    private func time(for id: UUID) -> Binding<Date> {
        Binding(get: { times[id] ?? Date().addingTimeInterval(3600) }, set: { times[id] = $0 })
    }

    private func run() async {
        error = nil
        let batch = pending
        for (n, c) in batch.enumerated() {
            guard let i = model.clips.firstIndex(where: { $0.id == c.id }) else { continue }
            let label = "Clip \(n + 1) of \(batch.count), \(c.title)"
            do {
                var file = model.clips[i].renderedURL
                if file == nil || !FileManager.default.fileExists(atPath: file!.path) {
                    working = "\(label): making the clip…"
                    progress = 0
                    file = try await ClipRenderer.render(clip: model.clips[i], analysis: analysis) { p in
                        Task { @MainActor in progress = p }
                    }
                    model.clips[i].renderedURL = file
                }
                working = "\(label): uploading…"
                progress = nil
                let when = times[c.id] ?? Date().addingTimeInterval(3600)
                try await posts.schedule(file: file!, clip: model.clips[i], at: when, autoPost: autoPost && instagramConnected,
                                         youtube: youtube && session.youtubeChannel != nil, sourceAssetID: analysis.sourceAssetID)
                model.clips[i].scheduledFor = when
                done += 1
            } catch {
                self.error = "\(c.title): \(error.localizedDescription) The clips before it are scheduled."
                working = nil
                return
            }
        }
        working = nil
        dismiss()
    }
}
