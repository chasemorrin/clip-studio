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
    @State private var pushBack = false
    @State private var working: String?
    @State private var progress: Double?
    @State private var error: String?

    private var instagramConnected: Bool { session.instagramUsername != nil }

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
                if instagramConnected {
                    Section {
                        Button {
                            Task { await schedule(postNow: true) }
                        } label: {
                            Label("Post to Instagram now", systemImage: "paperplane.fill")
                        }
                        .disabled(working != nil)
                    } footer: {
                        Text("Skips the calendar time. Usually live on Instagram within 1–3 minutes.")
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
            }
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
            let id = try await posts.schedule(file: file, clip: clip, at: at, autoPost: postNow || (autoPost && instagramConnected),
                                              sourceAssetID: analysis.sourceAssetID)
            if postNow {
                working = "Sending to Instagram…"
                try await posts.postNow(id: id)
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
                    } footer: {
                        if !instagramConnected { Text("Connect Instagram in Settings to post automatically.") }
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
                                         sourceAssetID: analysis.sourceAssetID)
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
