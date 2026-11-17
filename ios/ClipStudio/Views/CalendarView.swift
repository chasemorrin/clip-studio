import Photos
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

    enum Mode: String, CaseIterable { case list = "List", month = "Month" }
    @AppStorage("calendarMode") private var mode: Mode = .list

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: listView
                case .month: MonthCalendarView(editing: $editing)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
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

    private var listView: some View {
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
            .refreshable { await posts.refresh() }
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
    @State private var earliest = Date()
    @State private var title = ""
    @State private var caption = ""
    @State private var autoPost = false
    @State private var pushBack = false
    @State private var saving = false
    @State private var error: String?
    @State private var previewFiles: [URL] = []
    @State private var savingToPhotos = false
    @State private var savedToPhotos = false

    /// The latest copy from the server (it changes after re-editing the clip).
    private var current: Post { posts.posts.first { $0.id == post.id } ?? post }

    /// True when the date picker is on a different day than the post's saved day.
    private var movedDay: Bool {
        guard let at = current.publishAt else { return true }
        return !Calendar.current.isDate(at, inSameDayAs: when)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PostMediaPreview(post: current, files: $previewFiles)
                        .listRowInsets(EdgeInsets())
                    if current.isEditable, current.media.count == 1, current.media.first?.isVideo == true {
                        NavigationLink {
                            ClipReeditView(post: current, plan: current.plan)
                        } label: {
                            Label(current.plan != nil ? "Edit clip: trim, text and framing" : "Edit video: trim and framing",
                                  systemImage: "scissors")
                        }
                    }
                }
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section {
                    DatePicker("Post on", selection: $when, in: earliest..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("Post to Instagram automatically", isOn: $autoPost)
                        .disabled(session.instagramUsername == nil)
                } footer: {
                    if session.instagramUsername == nil { Text("Connect Instagram in Settings to post automatically.") }
                }
                if movedDay {
                    PushBackSection(day: when, excluding: post.id, isOn: $pushBack)
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
                if !current.media.isEmpty {
                    Section {
                        Button {
                            Task { await saveToPhotos() }
                        } label: {
                            Label(savingToPhotos ? "Saving…" : savedToPhotos ? "Saved to Photos" : "Save to Photos",
                                  systemImage: savedToPhotos ? "checkmark" : "square.and.arrow.down")
                        }
                        .disabled(savingToPhotos || savedToPhotos)
                    } footer: {
                        Text("Saves the \(current.media.count > 1 ? "photos" : current.media.first?.isVideo == true ? "video" : "photo") exactly as it will post.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .scrollDismissesKeyboard(.interactively)
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
                                let push = pushBack && movedDay
                                try await posts.update(current, title: title, publishAt: when, caption: caption, autoPost: autoPost)
                                await posts.pushBackAfterScheduling(push, day: when, newID: post.id)
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
            .onChange(of: current.media.map(\.key)) { _, _ in savedToPhotos = false }
            // After re-editing the clip, pick up its new title and caption.
            .onChange(of: current.caption) { _, v in caption = v }
            .onChange(of: current.title) { _, v in title = v }
        }
    }
}

extension PostEditSheet {
    func saveToPhotos() async {
        savingToPhotos = true
        defer { savingToPhotos = false }
        do {
            let files = previewFiles.count == current.media.count ? previewFiles : try await PostFiles.download(current, posts: posts)
            for (file, m) in zip(files, current.media) {
                try await PostFiles.saveToPhotos(file, isVideo: m.isVideo)
            }
            savedToPhotos = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Downloads a post's files to the phone, and saves them to Photos.
enum PostFiles {
    static func download(_ post: Post, posts: PostsStore) async throws -> [URL] {
        var got: [URL] = []
        for m in post.media {
            let remote = try await posts.previewURL(for: m)
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw APIError(code: "http_\(code)", message: "the server answered \(code).") }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("post-\(UUID().uuidString.prefix(8)).\(m.isVideo ? "mp4" : "jpg")")
            try FileManager.default.moveItem(at: tmp, to: dest)
            got.append(dest)
        }
        return got
    }

    static func saveToPhotos(_ file: URL, isVideo: Bool) async throws {
        if isVideo { return try await ClipRenderer.saveToPhotos(file) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw APIError(code: "photos_denied", message: "Clip Studio isn't allowed to save to Photos. Turn it on in Settings → Clip Studio → Photos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: file)
        }
    }
}

/// Plays a post's video (or shows its photos). Downloads the file to the phone first,
/// which is more reliable than streaming it.
struct PostMediaPreview: View {
    let post: Post
    @Binding var files: [URL]
    @EnvironmentObject var posts: PostsStore
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        ZStack {  // a real container, so .task below runs once instead of restarting whenever the content switches
            if post.media.isEmpty {
                placeholder(post.state == .posted ? "Posted. The file was removed from the server after posting." : "No media attached.")
            } else if let failure {
                placeholder("Couldn't load the preview: \(failure)")
            } else if loading || files.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading preview…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if post.media.first?.isVideo == true, let player {
                VideoPlayer(player: player)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
            } else {
                TabView {
                    ForEach(files, id: \.self) { file in
                        if let img = UIImage(contentsOfFile: file.path) {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            placeholder("This file can't be shown.")
                        }
                    }
                }
                .tabViewStyle(.page)
                .frame(height: 380)
                .background(Color.black)
            }
        }
        .task(id: post.media.map(\.key).joined(separator: ",")) { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        guard !post.media.isEmpty else { return }
        loading = true
        failure = nil
        defer { loading = false }
        let got: [URL]
        do {
            got = try await PostFiles.download(post, posts: posts)
        } catch {
            failure = error.localizedDescription
            return
        }
        files = got
        if post.media.first?.isVideo == true, let first = got.first {
            player = AVPlayer(url: first)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 80).padding(.horizontal)
    }
}

/// Reopens a scheduled video in the editor: from its original video in Photos when the app knows it
/// (trim, text and framing come back as you left them), otherwise from the scheduled video itself.
struct ClipReeditView: View {
    let post: Post
    let plan: ClipPlan?
    @EnvironmentObject var posts: PostsStore
    @State private var clip: ClipSuggestion
    @State private var analysis: VideoAnalysis?
    @State private var status: String
    @State private var progress: Double?
    @State private var failure: String?

    init(post: Post, plan: ClipPlan?) {
        self.post = post
        self.plan = plan
        var c = plan?.suggestion ?? ClipSuggestion(start: 0, end: 1, title: post.title, why: "", onScreenText: "",
                                                   caption: post.caption, hashtags: [])
        if plan == nil { c.framing = Framing(zoom: 1) }
        _clip = State(initialValue: c)
        _status = State(initialValue: plan != nil ? "Finding the original video…" : "Downloading the video…")
    }

    var body: some View {
        ZStack {  // a real container, so .task below runs once
            if let analysis {
                VStack(spacing: 0) {
                    if plan == nil {
                        Text("Editing the scheduled video. Its on-screen text is already part of the picture.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
                    }
                    ClipEditorView(clip: $clip, analysis: analysis) { file, edited in
                        let latest = posts.posts.first { $0.id == post.id } ?? post
                        try await posts.replaceClip(latest, file: file, clip: edited, sourceAssetID: plan?.assetId)
                    }
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't reopen this video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else {
                VStack(spacing: 14) {
                    if let progress { ProgressView(value: progress).frame(maxWidth: 240) } else { ProgressView() }
                    Text(status).font(.headline)
                    Text(plan != nil ? "Your trim, text and framing come back as you left them." : "This post doesn't know its original video, so you'll edit the scheduled one.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle(post.title.isEmpty ? "Edit video" : post.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard analysis == nil, failure == nil else { return }
            do {
                let url: URL
                if let plan {
                    url = try await SourceVideo.load(assetId: plan.assetId)
                } else {
                    guard let first = try await PostFiles.download(post, posts: posts).first else {
                        throw APIError(code: "missing", message: "This post has no video.")
                    }
                    url = first
                }
                var a = try await VideoAnalyzer.analyze(url: url, minimumDuration: 1, requireAudio: false) { p, label in
                    Task { @MainActor in progress = p; status = label }
                }
                a.sourceAssetID = plan?.assetId
                if plan == nil {
                    clip.start = 0
                    clip.end = a.duration
                } else {
                    clip.end = min(clip.end, a.duration)
                }
                analysis = a
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
