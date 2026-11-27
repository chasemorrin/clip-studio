import Photos
import AVKit
import SwiftUI

/// What's scheduled and what's been posted.
struct CalendarView: View {
    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore
    @State private var editing: Post?
    @State private var swapTarget: String?
    @State private var swapError: String?
    @State private var pendingSwap: PendingSwap?

    /// One post dropped on another, waiting for "swap" or "push back".
    struct PendingSwap: Identifiable {
        let id = UUID()
        let dragged: Post
        let target: Post
    }

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = posts.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                if posts.upcoming.isEmpty && !posts.loading {
                    ContentUnavailableView {
                        Label("Nothing scheduled", systemImage: "calendar")
                    } description: {
                        Text("Make clips in the Clips tab, then tap Schedule.")
                    }
                    .padding(.top, 40)
                }
                if !posts.upcoming.isEmpty {
                    Text("Tap a post to edit it. Touch and hold for more options, or drag it onto another post to swap their times.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                ForEach(groups) { group in
                    dayHeader(group.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    ForEach(group.posts) { post in
                        swappable(card(post), post: post)
                            .dropDestination(for: String.self) { ids, _ in
                                swap(ids.first, onto: post)
                            } isTargeted: { on in
                                if on { swapTarget = post.id } else if swapTarget == post.id { swapTarget = nil }
                            }
                    }
                }
                if !posts.recentlyPosted.isEmpty {
                    dayHeader("Posted")
                    ForEach(posts.recentlyPosted.prefix(20)) { post in card(post) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .refreshable { await posts.refresh() }
        .alert("Can't move these posts", isPresented: Binding(get: { swapError != nil }, set: { if !$0 { swapError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(swapError ?? "")
        }
        .confirmationDialog(pendingSwap.map { "Move \"\($0.dragged.title.isEmpty ? "Untitled" : $0.dragged.title)\"" } ?? "",
                            isPresented: Binding(get: { pendingSwap != nil }, set: { if !$0 { pendingSwap = nil } }),
                            titleVisibility: .visible, presenting: pendingSwap) { p in
            Button("Swap the two posts") {
                Task { do { try await posts.swapTimes(p.dragged, p.target) } catch { swapError = error.localizedDescription } }
            }
            Button("Take its place and push the others back") {
                Task {
                    guard let slot = p.target.publishAt else { return }
                    do {
                        try await posts.moveTo(p.dragged, at: slot)
                        try await posts.pushBack(from: slot, excluding: p.dragged.id)
                    } catch { swapError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("Swap trades their dates and times. Pushing back puts it at \(p.target.publishAt?.formatted(whenFormatShort) ?? "that time") and moves \"\(p.target.title.isEmpty ? "Untitled" : p.target.title)\", and any posts after it that are in the way, to your next open posting slots.")
        }
    }

    private func dayHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.leading, 4)
    }

    /// One post as a card: tap to edit, touch and hold for actions.
    private func card(_ post: Post) -> some View {
        let target = swapTarget == post.id
        return PostRow(post: post)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(target ? Theme.accent.opacity(0.25) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(target ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { if post.isEditable { editing = post } }
            .contextMenu { PostMenu(post: post, editing: $editing) }
    }

    /// Posts that can still change can be picked up and dropped on another post.
    @ViewBuilder
    private func swappable(_ row: some View, post: Post) -> some View {
        if post.isEditable {
            row.draggable(post.id) {
                Text(post.title.isEmpty ? "Untitled" : post.title)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(post.displayColor, in: Capsule())
            }
        } else {
            row
        }
    }

    /// Drop one post on another: they trade dates and times.
    private func swap(_ id: String?, onto target: Post) -> Bool {
        swapTarget = nil
        guard let id, id != target.id, let dragged = posts.posts.first(where: { $0.id == id }) else { return false }
        guard dragged.isEditable, target.isEditable else {
            swapError = "Posts that are posting or already posted can't be moved."
            return false
        }
        let soon = Date().addingTimeInterval(120)
        guard (dragged.publishAt ?? .distantPast) > soon, (target.publishAt ?? .distantPast) > soon else {
            swapError = "One of these posts' times has already passed. Open it and pick a new time instead."
            return false
        }
        pendingSwap = PendingSwap(dragged: dragged, target: target)
        return true
    }
}

/// Touch and hold a post (List or Month): Edit, Post Now, Don't Post, Delete.
struct PostMenu: View {
    let post: Post
    @Binding var editing: Post?
    @EnvironmentObject var posts: PostsStore
    @EnvironmentObject var session: SessionStore

    /// Instagram is switched on for this post (and can still post).
    private var instagramOn: Bool {
        session.instagramUsername != nil && (post.state == .scheduled || post.state == .failed)
    }

    /// YouTube is switched on for this post (and can still post).
    private var youtubeOn: Bool {
        session.youtubeChannel != nil && post.hasVideo
            && (post.youtube.state == .scheduled || post.youtube.state == .failed)
    }

    var body: some View {
        if post.isEditable {
            Button { editing = post } label: { item("Edit", "pencil") }
            if instagramOn || youtubeOn {
                // Posts now to whichever platforms are switched on for this post.
                Button {
                    let ig = instagramOn, yt = youtubeOn
                    Task {
                        do { try await posts.postNow(id: post.id, instagram: ig, youtube: yt) }
                        catch { posts.error = error.localizedDescription }
                    }
                } label: { item("Post Now", "paperplane.fill") }
                // Switches off whichever platforms are on; it stays on the calendar.
                Button {
                    let ig = instagramOn, yt = youtubeOn
                    Task { await posts.stopPosting(post, instagram: ig, youtube: yt) }
                } label: { item("Don't Post", "xmark.circle") }
            }
        }
        if post.state != .posting && post.youtube.state != .uploading {
            Button(role: .destructive) { Task { await posts.delete(post) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Menus tint icons with the app's gold; an "original" white image keeps its color.
    private func item(_ title: String, _ icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            if let ui = UIImage(systemName: icon)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                Image(uiImage: ui)
            } else {
                Image(systemName: icon)
            }
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
                VStack(alignment: .trailing, spacing: 3) {
                    // A YouTube-only post isn't a reminder: don't show "Reminder only" for its Instagram side.
                    if !(post.youtube.isOn && post.state == .notAutoPosting) { StatusPill(state: post.state) }
                    if post.youtube.isOn { YouTubePill(status: post.youtube) }
                }
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
            if let e = post.youtube.error {
                Text("YouTube: \(e)").font(.footnote).foregroundStyle(post.youtube.state == .failed ? Color.red : Color.orange)
            }
            if post.permalink != nil || post.youtube.url != nil {
                HStack(spacing: 14) {
                    if let link = post.permalink { Link("Open on Instagram", destination: link) }
                    if let link = post.youtube.url { Link("Open on YouTube", destination: link) }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Short date and time for dialogs, e.g. "Wed, Nov 26, 11:30 AM".
let whenFormatShort = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute()

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
        HStack(spacing: 3) {
            Image(systemName: "camera.fill").font(.caption2)
            Text(text)
        }
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
    @State private var youtube = false
    @State private var youtubeTitle = ""
    @State private var youtubeTags = ""
    @State private var pushBack = false
    @State private var saving = false
    @State private var error: String?
    @State private var previewFiles: [URL] = []
    @State private var savingToPhotos = false
    @State private var savedToPhotos = false

    /// The latest copy from the server (it changes after re-editing the clip).
    private var current: Post { posts.posts.first { $0.id == post.id } ?? post }

    /// The Short's description: the Instagram caption's text with YouTube's hashtags.
    var youtubeDescription: String {
        DefaultHashtags.caption(DefaultHashtags.split(caption).body, tags: youtubeTags)
    }

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
                WhenSection(when: $when, earliest: earliest, excluding: post.id)
                if movedDay {
                    PushBackSection(day: when, excluding: post.id, isOn: $pushBack)
                }
                InstagramPostSection(autoPost: $autoPost, post: current, busy: saving,
                                     postNow: { Task { await postNow(.instagram) } }, caption: $caption)
                if current.hasVideo || current.youtube.isOn {
                    YouTubeOptionsSection(isOn: $youtube, title: $youtubeTitle, status: current.youtube, busy: saving,
                                          postNow: current.hasVideo ? { Task { await postNow(.youtube) } } : nil,
                                          hashtags: $youtubeTags, instagramCaption: caption)
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
                                try await posts.update(current, title: title, publishAt: when, caption: caption, autoPost: autoPost,
                                                       youtube: session.youtubeChannel != nil ? youtube : nil,
                                                       youtubeTitle: youtube ? fullYouTubeTitle : nil,
                                                       youtubeDescription: youtubeDescription)
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
                youtube = post.youtube.isOn
                // The saved title already ends in its hashtags: split them back out to edit.
                let saved = YouTubeText.split(post.youtube.title ?? post.title)
                youtubeTitle = saved.base
                youtubeTags = DefaultHashtags.format(saved.tags.isEmpty
                    ? DefaultHashtags.split(post.youtube.description ?? post.caption).tags : saved.tags)
            }
            .onChange(of: current.media.map(\.key)) { _, _ in savedToPhotos = false }
            // After re-editing the clip, pick up its new title and caption.
            .onChange(of: current.caption) { _, v in caption = v }
            .onChange(of: current.title) { _, v in title = v }
        }
    }
}

extension PostEditSheet {
    /// The title YouTube gets: the title with the hashtags at the end (as many as fit).
    var fullYouTubeTitle: String {
        YouTubeText.title(youtubeTitle, tags: DefaultHashtags.parse(youtubeTags))
    }

    /// Saves the changes, then posts to one platform right away. The other keeps its scheduled time.
    func postNow(_ target: PostNowTarget) async {
        saving = true
        defer { saving = false }
        do {
            try await posts.update(current, title: title, publishAt: when, caption: caption, autoPost: autoPost,
                                   youtube: session.youtubeChannel != nil ? youtube : nil, youtubeTitle: fullYouTubeTitle,
                                   youtubeDescription: youtubeDescription)
            try await posts.postNow(id: post.id, instagram: target == .instagram, youtube: target == .youtube)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

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
    @State private var playing = false
    @State private var loopObserver: NSObjectProtocol?
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
                // A plain video layer with our own controls. Apple's full player inside this scrolling
                // form can lock the app up when you scroll while it plays.
                PlayerLayerView(player: player)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
                    .overlay {
                        if !playing {
                            Image(systemName: "play.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 72, height: 72)
                                .background(.black.opacity(0.45), in: Circle())
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if playing {
                            Image(systemName: "pause.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
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
        .onDisappear {
            player?.pause()
            playing = false
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
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
            let p = AVPlayer(url: first)
            // Loop, like Instagram.
            loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                  object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero)
                p.play()
            }
            player = p
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
