import AVKit
import SwiftUI

/// What's scheduled and what's been posted.
struct CalendarView: View {
    @EnvironmentObject var posts: PostsStore
    @State private var editing: Post?

    private struct DayGroup: Identifiable {
        let day: Date
        let posts: [Post]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: posts.upcoming) { cal.startOfDay(for: $0.publishAt ?? .distantFuture) }
        return grouped.keys.sorted().map { DayGroup(day: $0, posts: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = posts.error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if posts.upcoming.isEmpty && !posts.loading {
                    ContentUnavailableView {
                        Label("Nothing scheduled", systemImage: "calendar")
                    } description: {
                        Text("Make clips in the Clips tab, then tap Schedule.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                        ForEach(group.posts) { post in
                            PostRow(post: post)
                                .contentShape(Rectangle())
                                .onTapGesture { if post.isEditable { editing = post } }
                                .swipeActions(edge: .leading) {
                                    if post.state != .posting {
                                        Button { Task { await posts.postNow(post) } } label: { Label("Post now", systemImage: "paperplane.fill") }
                                            .tint(Theme.accent)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if post.state != .posting {
                                        Button(role: .destructive) { Task { await posts.delete(post) } } label: { Label("Delete", systemImage: "trash") }
                                    }
                                    if post.state == .scheduled {
                                        Button { Task { await posts.setAutoPost(post, false) } } label: { Label("Don't post", systemImage: "pause") }
                                            .tint(.gray)
                                    }
                                    if post.state == .failed {
                                        Button { Task { await posts.retry(post) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                            .tint(.blue)
                                    }
                                }
                        }
                    }
                }
                if !posts.recentlyPosted.isEmpty {
                    Section("Posted") {
                        ForEach(posts.recentlyPosted.prefix(20)) { post in PostRow(post: post) }
                    }
                }
            }
            .navigationTitle("Calendar")
            .refreshable { await posts.refresh() }
            .task {
                // Keep statuses fresh while this screen is open: every few seconds while
                // something is posting (or about to), otherwise every 30 seconds.
                while !Task.isCancelled {
                    await posts.refresh()
                    try? await Task.sleep(for: .seconds(posts.somethingIsHappening ? 4 : 30))
                }
            }
            .sheet(item: $editing) { post in PostEditSheet(post: post) }
        }
    }
}

struct PostRow: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(post.title.isEmpty ? "Untitled" : post.title).font(.headline).lineLimit(2)
                Spacer()
                StatusPill(state: post.state)
            }
            if let at = post.publishAt {
                Text(at.formatted(.dateTime.hour().minute()))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !post.caption.isEmpty {
                Text(post.caption).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if post.state == .failed, let e = post.postError {
                Text(e).font(.footnote).foregroundStyle(.red)
            } else if let e = post.postError, post.state == .scheduled || post.state == .posting {
                Text(e).font(.footnote).foregroundStyle(.orange)
            }
            if let link = post.permalink {
                Link("Open on Instagram", destination: link).font(.footnote)
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusPill: View {
    let state: Post.State

    var body: some View {
        let (text, color): (String, Color) = {
            switch state {
            case .scheduled: return ("Scheduled", Theme.accent)
            case .posting: return ("Posting…", .blue)
            case .posted: return ("Posted", .green)
            case .failed: return ("Failed", .red)
            case .notAutoPosting: return ("Reminder only", .gray)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct PostEditSheet: View {
    let post: Post
    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date()
    @State private var title = ""
    @State private var caption = ""
    @State private var autoPost = false
    @State private var saving = false
    @State private var error: String?

    /// The latest copy from the server (it changes after re-editing the clip).
    private var current: Post { posts.posts.first { $0.id == post.id } ?? post }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PostMediaPreview(post: current)
                        .listRowInsets(EdgeInsets())
                    if let plan = current.plan, current.isEditable {
                        NavigationLink {
                            ClipReeditView(post: current, plan: plan)
                        } label: {
                            Label("Edit clip: trim, text and framing", systemImage: "scissors")
                        }
                    }
                }
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section {
                    DatePicker("Post on", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("Post to Instagram automatically", isOn: $autoPost)
                        .disabled(session.instagramUsername == nil)
                } footer: {
                    if session.instagramUsername == nil { Text("Connect Instagram in Settings to post automatically.") }
                }
                Section("Caption") {
                    CaptionEditor(text: $caption, minHeight: 140)
                    if caption.contains("[") {
                        Text("Fill in the [brackets] before it posts.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if session.instagramUsername != nil {
                    Section {
                        Button {
                            Task {
                                saving = true
                                defer { saving = false }
                                do {
                                    try await posts.update(current, title: title, publishAt: Date().addingTimeInterval(60), caption: caption, autoPost: true)
                                    try await posts.postNow(id: post.id)
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Post to Instagram now", systemImage: "paperplane.fill")
                        }
                        .disabled(saving)
                    } footer: {
                        Text("Saves your changes and posts right away. Usually live within 1–3 minutes.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await posts.update(current, title: title, publishAt: when, caption: caption, autoPost: autoPost)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear {
                when = max(post.publishAt ?? Date(), Date().addingTimeInterval(120))
                caption = post.caption
                title = post.title
                autoPost = post.state == .scheduled || post.state == .failed
            }
            // After re-editing the clip, pick up its new title and caption.
            .onChange(of: current.caption) { _, v in caption = v }
            .onChange(of: current.title) { _, v in title = v }
        }
    }
}

/// Plays a post's video (or shows its photos) from the server.
struct PostMediaPreview: View {
    let post: Post
    @EnvironmentObject var posts: PostsStore
    @State private var urls: [URL] = []
    @State private var player: AVPlayer?
    @State private var loaded = false

    var body: some View {
        Group {
            if post.media.isEmpty {
                placeholder(post.state == .posted ? "Posted. The file was removed from the server after posting." : "No media attached.")
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if urls.isEmpty {
                placeholder("Couldn't load the preview.")
            } else if post.media.first?.isVideo == true, let player {
                VideoPlayer(player: player)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
            } else {
                TabView {
                    ForEach(urls, id: \.self) { url in
                        AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    }
                }
                .tabViewStyle(.page)
                .frame(height: 380)
                .background(Color.black)
            }
        }
        .task(id: post.media.map(\.key).joined()) {
            loaded = false
            var list: [URL] = []
            for m in post.media { if let u = await posts.previewURL(for: m) { list.append(u) } }
            urls = list
            if post.media.first?.isVideo == true, let first = list.first {
                player = AVPlayer(url: first)
            }
            loaded = true
        }
        .onDisappear { player?.pause() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// Reopens a scheduled clip in the editor from its original video in Photos.
struct ClipReeditView: View {
    let post: Post
    let plan: ClipPlan
    @EnvironmentObject var posts: PostsStore
    @State private var clip: ClipSuggestion
    @State private var analysis: VideoAnalysis?
    @State private var status = "Finding the original video…"
    @State private var progress: Double?
    @State private var failure: String?

    init(post: Post, plan: ClipPlan) {
        self.post = post
        self.plan = plan
        _clip = State(initialValue: plan.suggestion)
    }

    var body: some View {
        Group {
            if let analysis {
                ClipEditorView(clip: $clip, analysis: analysis) { file, edited in
                    let latest = posts.posts.first { $0.id == post.id } ?? post
                    try await posts.replaceClip(latest, file: file, clip: edited, sourceAssetID: plan.assetId)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't reopen this clip", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else {
                VStack(spacing: 14) {
                    if let progress { ProgressView(value: progress).frame(maxWidth: 240) } else { ProgressView() }
                    Text(status).font(.headline)
                    Text("Your trim, text and framing come back as you left them.").font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .navigationTitle(plan.title.isEmpty ? "Edit clip" : plan.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard analysis == nil, failure == nil else { return }
            do {
                let url = try await SourceVideo.load(assetId: plan.assetId)
                var a = try await VideoAnalyzer.analyze(url: url) { p, label in
                    Task { @MainActor in progress = p; status = label }
                }
                a.sourceAssetID = plan.assetId
                analysis = a
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
