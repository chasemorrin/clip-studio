import SwiftUI

/// A friend or collaborator you tag often.
struct FriendHandle: Codable, Hashable, Identifiable {
    var handle: String
    var name: String
    var id: String { handle }
}

enum FriendHandles {
    static let storageKey = "friendHandles"

    static func decode(_ json: String) -> [FriendHandle] {
        (try? JSONDecoder().decode([FriendHandle].self, from: Data(json.utf8))) ?? []
    }

    static func encode(_ list: [FriendHandle]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// "@Some.Name " → "some.name". Nil if it isn't a valid Instagram username.
    static func normalize(_ raw: String) -> String? {
        let h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        guard (1...30).contains(h.count), h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else { return nil }
        return h
    }
}

/// A caption box that suggests your saved handles as you type "@", like Instagram does.
struct CaptionEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    @AppStorage(FriendHandles.storageKey) private var handlesJSON = "[]"
    @State private var selection: TextSelection?

    private var handles: [FriendHandle] { FriendHandles.decode(handlesJSON) }

    /// The "@partial" word the cursor is in, if any.
    private var mention: (range: Range<String.Index>, query: String)? {
        guard let selection, case .selection(let r) = selection.indices else { return nil }
        let cursor = r.upperBound
        guard cursor >= text.startIndex, cursor <= text.endIndex else { return nil }
        var i = cursor
        while i > text.startIndex {
            let prev = text.index(before: i)
            let ch = text[prev]
            if ch == "@" {
                // Only at the start of a word, so emails don't trigger it.
                if prev > text.startIndex, !text[text.index(before: prev)].isWhitespace { return nil }
                return (prev..<cursor, String(text[text.index(after: prev)..<cursor]).lowercased())
            }
            guard ch.isLetter || ch.isNumber || ch == "." || ch == "_" else { return nil }
            i = prev
        }
        return nil
    }

    private var suggestions: [FriendHandle] {
        guard let m = mention else { return [] }
        let q = m.query
        return Array(handles
            .filter { q.isEmpty || $0.handle.hasPrefix(q) || $0.name.lowercased().contains(q) || $0.handle.contains(q) }
            .sorted { ($0.handle.hasPrefix(q) ? 0 : 1, $0.handle) < ($1.handle.hasPrefix(q) ? 0 : 1, $1.handle) }
            .prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text, selection: $selection)
                .frame(minHeight: minHeight)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { h in
                            Button { insert(h) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(h.handle)").font(.subheadline.weight(.semibold))
                                    if !h.name.isEmpty {
                                        Text(h.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if handles.isEmpty && mention != nil {
                Text("Add friends' handles in Settings to see suggestions here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func insert(_ h: FriendHandle) {
        guard let m = mention else { return }
        let replacement = "@\(h.handle) "
        let offset = text.distance(from: text.startIndex, to: m.range.lowerBound)
        text.replaceSubrange(m.range, with: replacement)
        let cursor = text.index(text.startIndex, offsetBy: min(text.count, offset + replacement.count))
        selection = TextSelection(insertionPoint: cursor)
    }
}

/// Settings section for managing saved handles.
struct FriendHandlesSection: View {
    @AppStorage(FriendHandles.storageKey) private var handlesJSON = "[]"
    @State private var newHandle = ""
    @State private var newName = ""
    @State private var problem: String?

    private var handles: [FriendHandle] { FriendHandles.decode(handlesJSON).sorted { $0.handle < $1.handle } }

    var body: some View {
        Section {
            ForEach(handles) { h in
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(h.handle)").font(.body.weight(.medium))
                    if !h.name.isEmpty { Text(h.name).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .onDelete { offsets in
                var list = handles
                list.remove(atOffsets: offsets)
                handlesJSON = FriendHandles.encode(list)
            }
            HStack {
                TextField("@handle", text: $newHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: $newName)
                Button("Add", action: add)
                    .disabled(newHandle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Friends & collaborators")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem { Text(problem).foregroundStyle(.red) }
                Text("Type @ in any caption to pick from these. Add a name so you can find people by name too. Swipe left to remove.")
            }
        }
    }

    private func add() {
        problem = nil
        // Allow pasting several at once, separated by spaces or commas.
        let parts = newHandle.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        var list = FriendHandles.decode(handlesJSON)
        for p in parts {
            guard let h = FriendHandles.normalize(p) else { problem = "\"\(p)\" isn't a valid Instagram handle."; continue }
            if let i = list.firstIndex(where: { $0.handle == h }) {
                if parts.count == 1 && !newName.isEmpty { list[i].name = newName }
            } else {
                list.append(FriendHandle(handle: h, name: parts.count == 1 ? newName.trimmingCharacters(in: .whitespaces) : ""))
            }
        }
        handlesJSON = FriendHandles.encode(list)
        if problem == nil { newHandle = ""; newName = "" }
    }
}
