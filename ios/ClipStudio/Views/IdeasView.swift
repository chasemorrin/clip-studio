import SwiftUI

/// Post ideas: generate new ones with AI, keep a running list, and turn one into a post.
struct IdeasView: View {
    @EnvironmentObject var posts: PostsStore
    @AppStorage("ideaEngine") private var engineRaw = IdeaEngine.apple.rawValue
    @AppStorage("ideaUseProfile") private var useProfile = true
    @AppStorage("ideaBrief") private var customBrief = ""
    @State private var generating = false
    @State private var error: String?
    @State private var lastEngine: IdeaEngine?
    @State private var adding = false
    @State private var open: Post?

    private var engine: IdeaEngine { IdeaEngine(rawValue: engineRaw) ?? .apple }
    private var appleStatus: (available: Bool, reason: String?) { IdeaGenerator.appleStatus }
    private var active: [Post] { posts.ideas.filter { $0.status != "posted" } }
    private var done: [Post] { posts.ideas.filter { $0.status == "posted" } }

    var body: some View {
        NavigationStack {
            List {
                generator
                Section {
                    if active.isEmpty {
                        Text("No ideas yet. Generate some above, or tap + to add your own.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(active) { idea in
                        Button { open = idea } label: { IdeaRow(idea: idea) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in delete(offsets.map { active[$0] }) }
                } header: {
                    Text(active.isEmpty ? "Your ideas" : "Your ideas (\(active.count))")
                }
                if !done.isEmpty {
                    Section("Done") {
                        ForEach(done) { idea in
                            Button { open = idea } label: { IdeaRow(idea: idea) }
                                .buttonStyle(.plain)
                        }
                        .onDelete { offsets in delete(offsets.map { done[$0] }) }
                    }
                }
            }
            .navigationTitle("Ideas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add your own idea", systemImage: "plus") }
                }
            }
            .refreshable { await posts.refresh() }
            .task { await posts.refresh() }
            .sheet(isPresented: $adding) { NewIdeaSheet() }
            .sheet(item: $open) { idea in IdeaDetailView(idea: idea) }
        }
    }

    // MARK: Generating

    private var generator: some View {
        Section {
            Picker("Based on", selection: $useProfile) {
                Text("Your music").tag(true)
                Text("Something else").tag(false)
            }
            .pickerStyle(.segmented)
            if useProfile {
                Text(Config.profile)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            } else {
                TextField("What are you looking for? e.g. short teaching tips on polyrhythm, or behind the scenes at gigs",
                          text: $customBrief, axis: .vertical)
                    .lineLimit(3...8)
            }
            Picker("Write ideas with", selection: $engineRaw) {
                ForEach(IdeaEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    Label(generating ? "Thinking…" : "Generate \(IdeaGenerator.count) ideas", systemImage: "sparkles")
                    if generating { Spacer(); ProgressView() }
                }
            }
            .disabled(generating || (!useProfile && customBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("New ideas")
        } footer: {
            if engine == .apple, !appleStatus.available, let reason = appleStatus.reason {
                Text("\(reason) Claude will write them instead.")
            } else if engine == .apple {
                Text("Apple Intelligence writes these on your iPhone, privately. Edit Your music in Settings.")
            } else {
                Text("Claude writes these. Edit Your music in Settings.")
            }
        }
    }

    private func generate() async {
        generating = true
        error = nil
        defer { generating = false }
        let brief = useProfile ? Config.profile : customBrief
        do {
            let drafts = try await IdeaGenerator.generate(brief: brief, avoid: posts.ideas.map(\.title), engine: engine)
            if drafts.isEmpty { error = "No ideas came back. Try again."; return }
            for d in drafts.reversed() {
                try await posts.createIdea(title: d.title, notes: d.notes, caption: d.caption, format: d.format)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ ideas: [Post]) {
        Task { for idea in ideas { await posts.delete(idea) } }
    }
}

/// One idea in the list: title, format and status.
struct IdeaRow: View {
    let idea: Post

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(idea.title.isEmpty ? "Untitled idea" : idea.title).font(.headline)
                if let hook = IdeaSections(idea.notes).value(for: "Hook") ?? IdeaSections(idea.notes).first {
                    Text(hook).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                IdeaStatusPill(status: idea.status)
                Text(idea.format.capitalized).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct IdeaStatusPill: View {
    let status: String

    static let all = ["idea", "planned", "filmed", "edited", "posted"]
    static func label(_ s: String) -> String { s == "posted" ? "Done" : s.capitalized }

    private var color: Color {
        switch status {
        case "planned": return .blue
        case "filmed": return .purple
        case "edited": return .orange
        case "posted": return .green
        default: return Theme.accent
        }
    }

    var body: some View {
        Text(Self.label(status))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Reads the "Label: text" paragraphs of an idea's breakdown.
struct IdeaSections {
    let parts: [(label: String?, text: String)]

    init(_ notes: String) {
        parts = notes.components(separatedBy: "\n\n").compactMap { para in
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return nil }
            if let colon = p.firstIndex(of: ":"), p.distance(from: p.startIndex, to: colon) <= 20 {
                return (String(p[..<colon]), p[p.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            return (nil, p)
        }
    }

    func value(for label: String) -> String? { parts.first { $0.label == label }?.text }
    var first: String? { parts.first?.text }
}

/// Add your own idea.
struct NewIdeaSheet: View {
    @EnvironmentObject var posts: PostsStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var format = "reel"
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Idea") {
                    TextField("Title", text: $title)
                    TextField("What's the post? What would you film?", text: $notes, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section("Format") {
                    Picker("Format", selection: $format) {
                        Text("Reel").tag("reel")
                        Text("Carousel").tag("carousel")
                        Text("Photo").tag("photo")
                    }
                    .pickerStyle(.segmented)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("New idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await posts.createIdea(title: title, notes: notes, format: format)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// One idea: its breakdown, status and caption draft, and "Add media" to make the post.
struct IdeaDetailView: View {
    let idea: Post
    @EnvironmentObject var posts: PostsStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var caption = ""
    @State private var format = "reel"
    @State private var status = "idea"
    @State private var editingBreakdown = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var changed: Bool {
        title != idea.title || notes != idea.notes || caption != idea.caption || format != idea.format || status != idea.status
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).font(.headline)
                    Picker("Status", selection: $status) {
                        ForEach(IdeaStatusPill.all, id: \.self) { Text(IdeaStatusPill.label($0)).tag($0) }
                    }
                    Picker("Format", selection: $format) {
                        Text("Reel").tag("reel")
                        Text("Carousel").tag("carousel")
                        Text("Photo").tag("photo")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        Task { await addMedia() }
                    } label: {
                        Label("Add media and make the post", systemImage: "photo.badge.plus")
                            .font(.headline)
                    }
                    .disabled(saving)
                } footer: {
                    Text("Opens the Clips tab to pick footage. Claude's clip picks and captions follow this idea, and the post you schedule replaces it on your calendar.")
                }

                Section {
                    if editingBreakdown {
                        TextField("Breakdown", text: $notes, axis: .vertical).lineLimit(6...30)
                    } else {
                        let parts = IdeaSections(notes).parts
                        if parts.isEmpty {
                            Text("No breakdown yet. Tap Edit to write one.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            VStack(alignment: .leading, spacing: 3) {
                                if let label = part.label {
                                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                }
                                Text(part.text).font(.callout)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Breakdown")
                        Spacer()
                        Button(editingBreakdown ? "Done" : "Edit") { editingBreakdown.toggle() }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }

                Section("Caption draft") {
                    CaptionEditor(text: $caption, minHeight: 120)
                }

                if let error { Section { Text(error).foregroundStyle(.red) } }

                Section {
                    Button("Delete idea", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await save() { dismiss() } } }
                        .disabled(saving || !changed)
                }
            }
            .confirmationDialog("Delete this idea?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await posts.delete(idea)
                        dismiss()
                    }
                }
            }
            .onAppear {
                title = idea.title
                notes = idea.notes
                caption = idea.caption
                format = idea.format
                status = idea.status
            }
        }
    }

    @discardableResult
    private func save() async -> Bool {
        guard changed else { return true }
        saving = true
        defer { saving = false }
        do {
            try await posts.updateIdea(idea, title: title, notes: notes, caption: caption, format: format, status: status)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Saves any edits, then hands the idea to the Clips tab.
    private func addMedia() async {
        guard await save() else { return }
        var latest = posts.posts.first { $0.id == idea.id } ?? idea
        latest.title = title
        latest.notes = notes
        latest.caption = caption
        IdeaLink.shared.start(latest)
        dismiss()
    }
}
