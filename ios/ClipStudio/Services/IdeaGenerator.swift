import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A post idea, before it's saved: what the post is and how to make it.
struct IdeaDraft {
    var title: String
    var format: String  // reel, carousel or photo
    var hook: String
    var concept: String
    var whatToFilm: String
    var caption: String
    var whyItWorks: String

    /// The breakdown, saved in the idea's notes so it can be read and edited.
    var notes: String {
        """
        Hook: \(hook)

        The idea: \(concept)

        What to film: \(whatToFilm)

        Why it works: \(whyItWorks)
        """
    }
}

/// Which AI writes the ideas.
enum IdeaEngine: String, CaseIterable, Identifiable {
    case apple, claude
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple Intelligence" : "Claude" }
}

enum IdeaGenerator {
    /// Whether Apple Intelligence can run here, and if not, why (for the screen).
    static var appleStatus: (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, nil)
            case .unavailable(.deviceNotEligible):
                return (false, "This iPhone can't run Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Apple Intelligence is turned off. Turn it on in the Settings app.")
            case .unavailable(.modelNotReady):
                return (false, "Apple Intelligence is still downloading. Try again later.")
            case .unavailable:
                return (false, "Apple Intelligence isn't available right now.")
            }
        }
        return (false, "Apple Intelligence needs iOS 26 or later.")
        #else
        return (false, "Apple Intelligence needs iOS 26 or later.")
        #endif
    }

    static let count = 5

    private static let instructions = """
    You help a musician come up with Instagram posts that make people stop scrolling and follow. \
    Ideas must be specific to his music and realistic to film with a phone in a practice room or at a gig. \
    Avoid generic advice, trends that don't fit him, and anything he'd be embarrassed to post.
    """

    private static func prompt(brief: String, avoid: [String]) -> String {
        var p = """
        About the musician and what he's looking for:
        \(brief)

        Write \(count) new Instagram post ideas for him. Mix formats (mostly reels, some carousels or photos).
        For each: a short title, the format, the hook (what's on screen or said in the first 2 seconds), \
        the idea in 1–2 sentences, what to film (concrete shots), a ready-to-post caption (2–4 sentences, \
        then 3–5 relevant hashtags), and why it works for his audience.
        """
        if !avoid.isEmpty {
            p += "\n\nHe already has these ideas, so don't repeat them:\n" + avoid.prefix(40).map { "- \($0)" }.joined(separator: "\n")
        }
        return p
    }

    static func generate(brief: String, avoid: [String], engine: IdeaEngine) async throws -> [IdeaDraft] {
        if engine == .apple {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), appleStatus.available {
                return try await withApple(brief: brief, avoid: avoid)
            }
            #endif
        }
        return try await withClaude(brief: brief, avoid: avoid)
    }

    // MARK: Apple Intelligence (on the phone)

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    enum GeneratedFormat {
        case reel, carousel, photo
    }

    @available(iOS 26.0, *)
    @Generable
    struct GeneratedIdea {
        @Guide(description: "A short, catchy title for the post, under 8 words")
        var title: String
        var format: GeneratedFormat
        @Guide(description: "What's on screen or said in the first 2 seconds to stop the scroll")
        var hook: String
        @Guide(description: "The idea in 1 or 2 sentences")
        var concept: String
        @Guide(description: "The concrete shots to film with a phone")
        var whatToFilm: String
        @Guide(description: "A ready-to-post caption of 2 to 4 sentences, ending with 3 to 5 relevant hashtags")
        var caption: String
        @Guide(description: "Why this works for his audience, in one sentence")
        var whyItWorks: String
    }

    @available(iOS 26.0, *)
    @Generable
    struct GeneratedIdeas {
        @Guide(description: "New Instagram post ideas", .count(5))
        var ideas: [GeneratedIdea]
    }

    @available(iOS 26.0, *)
    private static func withApple(brief: String, avoid: [String]) async throws -> [IdeaDraft] {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt(brief: brief, avoid: avoid), generating: GeneratedIdeas.self)
        return response.content.ideas.map { i in
            let format: String
            switch i.format {
            case .reel: format = "reel"
            case .carousel: format = "carousel"
            case .photo: format = "photo"
            }
            return IdeaDraft(title: i.title, format: format, hook: i.hook, concept: i.concept,
                             whatToFilm: i.whatToFilm, caption: i.caption, whyItWorks: i.whyItWorks)
        }
    }
    #endif

    // MARK: Claude (through the server)

    private static func withClaude(brief: String, avoid: [String]) async throws -> [IdeaDraft] {
        let text = try await APIClient.shared.askClaude(
            system: instructions + " Answer with JSON only.",
            content: [["type": "text", "text": prompt(brief: brief, avoid: avoid) + """


            Answer with a JSON array of \(count) objects with the keys: title, format ("reel", "carousel" or "photo"), \
            hook, concept, whatToFilm, caption, whyItWorks.
            """]],
            maxTokens: 3000)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
              let data = String(text[start...end]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError(code: "bad_ideas", message: "Claude's answer couldn't be read. Try again.")
        }
        return list.map { d in
            let s = { (k: String) in (d[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let f = s("format").lowercased()
            return IdeaDraft(title: s("title"), format: ["reel", "carousel", "photo"].contains(f) ? f : "reel",
                             hook: s("hook"), concept: s("concept"), whatToFilm: s("whatToFilm"),
                             caption: s("caption"), whyItWorks: s("whyItWorks"))
        }
        .filter { !$0.title.isEmpty }
    }
}
