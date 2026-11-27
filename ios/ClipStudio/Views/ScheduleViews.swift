import SwiftUI

private let whenFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()

/// Which platform to post to right away (the other keeps its scheduled time).
enum PostNowTarget { case instagram, youtube }

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
    @State private var youtubeTags = ""
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
                WhenSection(when: $when, nextSlot: nextSlot)
                PushBackSection(day: when, isOn: $pushBack)
                InstagramPostSection(autoPost: $autoPost, busy: working != nil,
                                     postNow: { Task { await schedule(now: .instagram) } }, captionText: clip.fullCaption)
                YouTubeOptionsSection(isOn: $youtube, title: $youtubeTitle, busy: working != nil,
                                      postNow: { Task { await schedule(now: .youtube) } }, hashtags: $youtubeTags)
                if !clip.carousel.isEmpty {
                    Section {
                        Label("Carousel of \(clip.carousel.count + 1) on Instagram. YouTube gets just the clip.",
                              systemImage: "square.stack")
                            .font(.footnote)
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
            .workingOverlay(working, progress: progress)
            .task {
                await posts.refresh()
                nextSlot = PostingSchedule.nextSlots(1, taken: posts.takenDays).first
                if let nextSlot { when = nextSlot }
                autoPost = session.instagramByDefault
                youtube = session.youtubeByDefault
                if youtubeTitle.isEmpty { youtubeTitle = clip.youtubeTitle ?? clip.title }
                if youtubeTags.isEmpty { youtubeTags = DefaultHashtags.format(clip.youtubeHashtags ?? clip.hashtags) }
            }
        }
    }

    private func schedule(now: PostNowTarget? = nil) async {
        error = nil
        await BackgroundWork.run("Scheduling post") { await doSchedule(now: now) }
    }

    private func doSchedule(now: PostNowTarget?) async {
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
            var extras: [(key: String, type: String)] = []
            if !clip.carousel.isEmpty {
                extras = try await ExtraMedia.upload(clip.carousel) { label, p in
                    working = label
                    progress = p
                }
            }
            working = "Uploading…"
            progress = nil
            let ytTags = DefaultHashtags.parse(youtubeTags)
            clip.youtubeHashtags = ytTags == clip.hashtags ? nil : ytTags
            let id = try await posts.schedule(file: file, clip: clip, at: when, autoPost: instagramConnected && autoPost,
                                              youtube: toYouTube, youtubeTitle: YouTubeText.title(youtubeTitle, tags: ytTags),
                                              extraMedia: extras, sourceAssetID: analysis.sourceAssetID)
            clip.youtubeTitle = youtubeTitle == clip.title ? nil : youtubeTitle
            switch now {
            case .instagram:
                working = "Sending to Instagram…"
                try await posts.postNow(id: id, instagram: true, youtube: false)
            case .youtube:
                working = "Sending to YouTube…"
                try await posts.postNow(id: id, instagram: false, youtube: true)
            case nil:
                if pushBack {
                    working = "Moving the other posts back…"
                    await posts.pushBackAfterScheduling(true, day: when, newID: id)
                }
            }
            clip.scheduledFor = when
            clip.keep = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
            working = nil
        }
    }
}

/// "When": the date (with dots on busy days) and time, plus a shortcut to the next open posting slot.
struct WhenSection: View {
    @Binding var when: Date
    var nextSlot: Date? = nil
    var earliest: Date = Date()
    var excluding: String? = nil

    var body: some View {
        Section {
            PostDateField(date: $when, earliest: earliest, excluding: excluding)
            if let nextSlot, abs(nextSlot.timeIntervalSince(when)) > 60 {
                Button("Use next open slot: \(nextSlot.formatted(whenFormat))") { when = nextSlot }
            }
        } header: {
            Text("When")
        } footer: {
            Text("Change your posting days and time in Settings.")
        }
    }
}

/// Instagram: post automatically at the time above, its status, and post now.
struct InstagramPostSection: View {
    @Binding var autoPost: Bool
    /// The post's current state, on the Calendar's edit page.
    var post: Post? = nil
    var busy = false
    var postNow: (() -> Void)? = nil
    /// The caption, shown read-only (scheduling a clip: it's edited in the clip editor)…
    var captionText: String? = nil
    /// …or editable (the Calendar's edit page).
    var caption: Binding<String>? = nil
    @EnvironmentObject var session: SessionStore

    private var connected: Bool { session.instagramUsername != nil }
    private var posted: Bool { post?.state == .posted }

    @ViewBuilder
    private var captionRow: some View {
        if let caption {
            VStack(alignment: .leading, spacing: 4) {
                Text("Caption").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                CaptionEditor(text: caption, minHeight: 120)
                if caption.wrappedValue.contains("[") {
                    Text("Fill in the [brackets] before it posts.").font(.caption).foregroundStyle(.orange)
                }
            }
        } else if let captionText {
            VStack(alignment: .leading, spacing: 4) {
                Text("Caption").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(captionText).font(.callout)
                if captionText.contains("[") {
                    Text("Fill in the [brackets] before it posts.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    var body: some View {
        Section {
            Toggle(isOn: $autoPost) {
                Label("Post automatically", systemImage: "camera")
            }
            .disabled(!connected || posted)
            captionRow
            if let post, post.state != .notAutoPosting {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Status").foregroundStyle(.secondary)
                        Spacer()
                        StatusPill(state: post.state)
                    }
                    if let e = post.postError {
                        Text(e).font(.footnote).foregroundStyle(post.state == .failed ? Color.red : Color.orange)
                    }
                    if let link = post.permalink {
                        Link("Open on Instagram", destination: link).font(.footnote)
                    }
                }
            }
            if let postNow, connected, !posted, post?.state != .posting {
                Button(action: postNow) {
                    Label("Post to Instagram now", systemImage: "paperplane.fill")
                }
                .disabled(busy)
            }
        } header: {
            Text("Instagram")
        } footer: {
            if !connected {
                Text("Connect Instagram in Settings to post automatically. Until then it stays on your calendar as a reminder.")
            } else if !posted {
                Text("Posts within 5 minutes of the time above. Post now skips the wait; usually live in 1–3 minutes.")
            }
        }
    }
}

/// YouTube: the same layout as Instagram, plus the Short's title.
struct YouTubeOptionsSection: View {
    @Binding var isOn: Bool
    @Binding var title: String
    /// The post's YouTube status, on the Calendar's edit page.
    var status: Post.YouTubeStatus? = nil
    var busy = false
    var postNow: (() -> Void)? = nil
    /// The Short's hashtags (copied from Instagram; can be changed here).
    var hashtags: Binding<String>? = nil
    /// The Instagram caption, for "Copy Instagram caption" into the title.
    var instagramCaption: String? = nil
    @EnvironmentObject var session: SessionStore

    private var connected: Bool { session.youtubeChannel != nil }
    private var posted: Bool { status?.state == .posted }

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                Label {
                    Text("Post automatically")
                } icon: {
                    Image(systemName: "play.rectangle").foregroundStyle(.red)
                }
            }
            .tint(.red)
            .disabled(!connected || posted)
            if isOn || posted {
                if let instagramCaption, !posted,
                   !instagramCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack {
                        Text("Title").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Instagram caption") {
                            title = DefaultHashtags.youtubeTitle(fromCaption: instagramCaption)
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    }
                }
                TextField("YouTube title", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                    .disabled(posted)
                    .onChange(of: title) { _, v in if v.count > 100 { title = String(v.prefix(100)) } }
                if let hashtags {
                    HashtagField(text: hashtags, label: "YouTube hashtags")
                        .disabled(posted)
                    if !posted {
                        YouTubeTitlePreview(base: title, tags: DefaultHashtags.parse(hashtags.wrappedValue))
                    }
                }
            }
            if let status, status.isOn {
                YouTubeStatusView(status: status)
            }
            if let postNow, connected, !posted, status?.state != .uploading {
                Button(action: postNow) {
                    Label("Post to YouTube now", systemImage: "paperplane.fill")
                        .foregroundStyle(busy ? Color.secondary : Color.red)
                }
                .disabled(busy)
            }
        } header: {
            Text("YouTube Shorts")
        } footer: {
            if !connected {
                Text("Connect YouTube in Settings to post Shorts too.")
            } else if !posted {
                Text(isOn ? "Same time as Instagram. The hashtags go at the end of the title, the way they go at the end of the Instagram caption."
                          : "Post now works even when this is off.")
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
                                PostDateField(date: time(for: c.id))
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
                        Toggle(isOn: $autoPost) { Label("Post to Instagram", systemImage: "camera") }
                            .disabled(!instagramConnected)
                        Toggle(isOn: $youtube) { Label("Post to YouTube Shorts", systemImage: "play.rectangle") }
                            .tint(.red)
                            .disabled(session.youtubeChannel == nil)
                    } footer: {
                        if !instagramConnected { Text("Connect Instagram in Settings to post automatically.") }
                        else if session.youtubeChannel == nil { Text("Connect YouTube in Settings to post Shorts too.") }
                        else if youtube { Text("Each Short uses the clip's YouTube title with its hashtags at the end. You can change it per post in Calendar.") }
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
            .workingOverlay(working, progress: progress)
            .task {
                await posts.refresh()
                let slots = PostingSchedule.nextSlots(pending.count, taken: posts.takenDays)
                for (c, slot) in zip(pending, slots) { times[c.id] = slot }
                autoPost = session.instagramByDefault
                youtube = session.youtubeByDefault
            }
        }
    }

    private func time(for id: UUID) -> Binding<Date> {
        Binding(get: { times[id] ?? Date().addingTimeInterval(3600) }, set: { times[id] = $0 })
    }

    private func run() async {
        error = nil
        await BackgroundWork.run("Scheduling clips") { await runBatch() }
    }

    private func runBatch() async {
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
                var extras: [(key: String, type: String)] = []
                if !model.clips[i].carousel.isEmpty {
                    extras = try await ExtraMedia.upload(model.clips[i].carousel) { step, p in
                        working = "\(label): \(step)"
                        progress = p
                    }
                }
                working = "\(label): uploading…"
                progress = nil
                let when = times[c.id] ?? Date().addingTimeInterval(3600)
                let clip = model.clips[i]
                let ytTitle = YouTubeText.title(clip.youtubeTitle ?? clip.title, tags: clip.youtubeHashtags ?? clip.hashtags)
                try await posts.schedule(file: file!, clip: clip, at: when, autoPost: autoPost && instagramConnected,
                                         youtube: youtube && session.youtubeChannel != nil, youtubeTitle: ytTitle,
                                         extraMedia: extras, sourceAssetID: analysis.sourceAssetID)
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
