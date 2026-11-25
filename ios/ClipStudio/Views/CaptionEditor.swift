import UIKit
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

/// A plain UIKit text view, so the app always knows where the cursor is and can move it.
struct CaptionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int            // UTF-16 offset of the cursor
    @Binding var pendingCursor: Int?    // set to move the cursor after inserting a handle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.autocapitalizationType = .sentences
        v.delegate = context.coordinator
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text { v.text = text }
        if let p = pendingCursor {
            let loc = min(p, (v.text as NSString).length)
            v.selectedRange = NSRange(location: loc, length: 0)
            DispatchQueue.main.async {
                pendingCursor = nil
                cursor = loc
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CaptionTextView
        init(_ parent: CaptionTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            let t = v.text ?? ""
            let c = v.selectedRange.location
            // Update SwiftUI after this UIKit callback finishes, never during a view update.
            DispatchQueue.main.async {
                if self.parent.text != t { self.parent.text = t }
                if self.parent.cursor != c { self.parent.cursor = c }
            }
        }

        func textViewDidChangeSelection(_ v: UITextView) {
            let c = v.selectedRange.location
            DispatchQueue.main.async {
                if self.parent.cursor != c { self.parent.cursor = c }
            }
        }
    }
}

/// A caption box that suggests your saved handles as you type "@", like Instagram does.
struct CaptionEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    @AppStorage(FriendHandles.storageKey) private var handlesJSON = "[]"
    @State private var cursor = 0
    @State private var pendingCursor: Int?

    private var handles: [FriendHandle] { FriendHandles.decode(handlesJSON) }

    /// The "@partial" word right before the cursor, as a UTF-16 range plus what's typed after the @.
    private var mention: (range: NSRange, query: String)? {
        let ns = text as NSString
        let end = min(cursor, ns.length)
        guard end > 0 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        var i = end
        while i > 0 {
            let unit = ns.character(at: i - 1)
            if unit == 64 { // "@"
                if i - 1 > 0, let s = UnicodeScalar(ns.character(at: i - 2)), !CharacterSet.whitespacesAndNewlines.contains(s) { return nil }
                let range = NSRange(location: i - 1, length: end - (i - 1))
                return (range, ns.substring(with: NSRange(location: i, length: end - i)).lowercased())
            }
            guard let s = UnicodeScalar(unit), allowed.contains(s), end - i < 31 else { return nil }
            i -= 1
        }
        return nil
    }

    private var suggestions: [FriendHandle] {
        guard let m = mention else { return [] }
        let q = m.query
        return Array(handles
            .filter { q.isEmpty || $0.handle.contains(q) || $0.name.lowercased().contains(q) }
            .sorted { ($0.handle.hasPrefix(q) ? 0 : 1, $0.handle) < ($1.handle.hasPrefix(q) ? 0 : 1, $1.handle) }
            .prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionTextView(text: $text, cursor: $cursor, pendingCursor: $pendingCursor)
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
        text = (text as NSString).replacingCharacters(in: m.range, with: replacement)
        pendingCursor = m.range.location + (replacement as NSString).length
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

/// Hashtags added to every new post, set in Settings.
enum DefaultHashtags {
    static let storageKey = "defaultHashtags"

    static var text: String { UserDefaults.standard.string(forKey: storageKey) ?? "" }
    static var list: [String] { parse(text) }

    /// "#jazz, piano #livemusic" → ["jazz", "piano", "livemusic"], without repeats.
    static func parse(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.components(separatedBy: CharacterSet(charactersIn: " ,\n\t#"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// ["jazz", "piano"] → "#jazz #piano"
    static func format(_ tags: [String]) -> String { tags.map { "#" + $0 }.joined(separator: " ") }

    /// A YouTube title from a caption: its text without the hashtags, on one line, at most 100 characters
    /// (cut at the last whole word).
    static func youtubeTitle(fromCaption caption: String) -> String {
        let text = split(caption).body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard text.count > 100 else { return text }
        let cut = String(text.prefix(100))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 60 {
            return String(cut[..<space])
        }
        return cut
    }

    /// Splits a full caption into its text and the hashtag-only lines at the end.
    static func split(_ full: String) -> (body: String, tags: [String]) {
        var lines = full.components(separatedBy: "\n")
        var tags: [String] = []
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.removeLast(); continue }
            let words = t.split(separator: " ")
            guard words.allSatisfy({ $0.hasPrefix("#") }) else { break }
            tags = parse(t) + tags
            lines.removeLast()
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), tags)
    }

    /// Caption with hashtags on their own lines at the end, as Instagram will show it.
    static func caption(_ caption: String, tags: String) -> String {
        let t = format(parse(tags))
        let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return c }
        return c.isEmpty ? t : "\(c)\n\n\(t)"
    }
}

struct DefaultHashtagsSection: View {
    @AppStorage(DefaultHashtags.storageKey) private var tags = ""

    var body: some View {
        Section {
            TextField("#jazz #jazzpiano #livemusic", text: $tags, axis: .vertical)
                .lineLimit(2...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Default hashtags")
        } footer: {
            Text("Added to every new post. When Claude picks its own hashtags, the editor has a button to switch to these.")
        }
    }
}

/// An editable hashtag field with a button to switch to your defaults.
struct HashtagField: View {
    @Binding var text: String
    var label = "Hashtags"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                let defaults = DefaultHashtags.list
                if !defaults.isEmpty && DefaultHashtags.parse(text).map({ $0.lowercased() }) != defaults.map({ $0.lowercased() }) {
                    Menu("Use my defaults") {
                        Button("Replace with my defaults") { text = DefaultHashtags.format(defaults) }
                        Button("Add my defaults") { text = DefaultHashtags.format(DefaultHashtags.parse(text + " " + DefaultHashtags.text)) }
                    }
                    .font(.footnote)
                }
            }
            TextField("#jazz #piano", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
