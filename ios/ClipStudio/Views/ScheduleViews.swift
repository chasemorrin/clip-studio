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
                Section {
                    Toggle("Post to Instagram automatically", isOn: $autoPost)
                        .disabled(!instagramConnected)
                } footer: {
                    Text(instagramConnected
                         ? "It posts within 5 minutes of the time you pick. You can change or cancel it in Calendar."
                         : "Connect Instagram in Settings to post automatically. Until then it goes on your calendar as a reminder.")
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

    private func schedule() async {
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
            try await posts.schedule(file: file, clip: clip, at: when, autoPost: autoPost && instagramConnected)
            clip.scheduledFor = when
            clip.keep = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
            working = nil
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
                try await posts.schedule(file: file!, clip: model.clips[i], at: when, autoPost: autoPost && instagramConnected)
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
