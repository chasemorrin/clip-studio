import Foundation
import UIKit

struct ClipSuggestion: Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var title: String
    var why: String
    var onScreenText: String
    var caption: String
    var hashtags: [String]
    var keep = false
    var fromClaude = true
    var framing: Framing? = nil   // nil until the editor sets it up
    var renderedURL: URL? = nil   // the finished clip, once made
    var scheduledFor: Date? = nil

    var length: Double { end - start }
    /// The Short's title on YouTube (the clip's title if empty).
    var youtubeTitle: String? = nil
    /// The Short's hashtags, if different from Instagram's (nil = the same).
    var youtubeHashtags: [String]? = nil
}

/// Saved with the project so its clips come back after leaving the screen. The exported file
/// (renderedURL) lives in a temporary folder, so it isn't saved; it's made again when needed.
extension ClipSuggestion: Codable {
    enum CodingKeys: String, CodingKey {
        case id, start, end, title, why, onScreenText, caption, hashtags, keep, fromClaude, framing, scheduledFor, youtubeTitle, youtubeHashtags
    }
}

func timecode(_ t: Double, tenths: Bool = false) -> String {
    let t = max(0, t)
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return tenths ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s))
}

/// Asks Claude to pick clips, using what the phone measured plus a handful of frames.
enum ClipSuggester {
    static func suggest(_ a: VideoAnalysis) async throws -> [ClipSuggestion] {
        let system = """
        You are the video editor for a jazz pianist's Instagram. You pick the strongest short clips from longer performance footage.

        About him, in his words: "\(Config.profile)"
        \(IdeaLink.brief.map { "\nThis post is for an idea he planned. Pick the clips that fit it best, and write captions for it:\n\($0)\n" } ?? "")
        How to pick and cut (learned from his feedback):
        - Start and end every clip on one of the listed breath times (quiet dips between phrases) whenever possible. Never cut mid-phrase.
        - Phone audio is compressed, so loudness alone won't show the climax. Use musical activity, the camera sections, and what the frames show (a piano solo close-up, dancers, the full band).
        - Favor moments that feature him at the piano, strong band interplay, builds, and endings that land. A clip that ends on the final hit of a tune is great.
        - Each clip 15–60 seconds, ideally 20–35. Suggest 3 to 6 clips that don't overlap much.
        - On-screen text: minimal and lowercase, like "piano solo, live" or "the trio, with dancers". Use an empty string if the music should speak for itself.
        - Captions: short and human, in the style of Danilo Pérez or Sullivan Fortner. Use [brackets] for anything you can't know, like the tune, venue, date or band members. Never invent names or places.

        - Hashtags: \(DefaultHashtags.list.isEmpty ? "pick 8–12 that fit the clip." : "his usual hashtags are \(DefaultHashtags.format(DefaultHashtags.list)). Keep the ones that fit this clip and add a few specific to it (instrument, style, setting), 8–12 in all.")

        Reply with only JSON, no other text:
        {"clips":[{"start":seconds,"end":seconds,"title":"short name for the moment","why":"one sentence on why it works","onScreenText":"","caption":"","hashtags":["8–12 tags without #"]}]}
        """

        var content: [[String: Any]] = []
        for f in pickFrames(a) {
            guard let jpeg = UIImage(cgImage: f.image).jpegData(compressionQuality: 0.6) else { continue }
            content.append(["type": "text", "text": "Frame at \(timecode(f.time)) (\(Int(f.time))s):"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": describe(a)])

        let text = try await APIClient.shared.askClaude(system: system, content: content, maxTokens: 3000)
        let clips = parse(text, analysis: a)
        if clips.isEmpty { throw APIError(code: "bad_answer", message: "Claude's answer didn't include any clips. Try again.") }
        return clips
    }

    /// Up to 16 frames: the start of every camera section, then evenly spaced extras.
    private static func pickFrames(_ a: VideoAnalysis) -> [VideoAnalysis.Frame] {
        guard !a.frames.isEmpty else { return [] }
        var chosen: [VideoAnalysis.Frame] = []
        func add(near t: Double) {
            guard let f = a.frames.min(by: { abs($0.time - t) < abs($1.time - t) }),
                  !chosen.contains(where: { abs($0.time - f.time) < 3 }) else { return }
            chosen.append(f)
        }
        for s in a.sections.prefix(10) { add(near: s.lowerBound + min(3, (s.upperBound - s.lowerBound) / 2)) }
        let target = 16
        var i = 0
        while chosen.count < target && i < target * 2 {
            add(near: a.duration * (Double(i) + 0.5) / Double(target))
            i += 1
        }
        return chosen.sorted { $0.time < $1.time }
    }

    private static func describe(_ a: VideoAnalysis) -> String {
        var s = "Video length: \(timecode(a.duration)) (\(Int(a.duration))s). \(a.isPortrait ? "Filmed vertically." : "Filmed horizontally.")\n"
        s += "Camera sections (seconds): " + a.sections.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" }.joined(separator: ", ") + "\n"
        s += "Breaths, good cut points (seconds): " + a.breaths.map { String(format: "%.1f", $0) }.joined(separator: ", ") + "\n"
        s += "Audio every 2 seconds: time s | loudness dB | activity 0-100 | noisiness 0-100 (high noisiness with low activity can mean applause or crowd)\n"
        let per = Int(2 / a.hop)
        var i = 0
        while i < a.loudness.count {
            let r = i..<min(a.loudness.count, i + per)
            let db = r.map { a.loudness[$0] }.reduce(0, +) / Float(r.count)
            let act = r.map { a.activity[$0] }.reduce(0, +) / Float(r.count)
            let noi = r.map { a.noisiness[$0] }.reduce(0, +) / Float(r.count)
            s += "\(Int(Double(i) * a.hop)) | \(Int(db.rounded())) | \(Int((act * 100).rounded())) | \(Int((noi * 100).rounded()))\n"
            i += per
        }
        return s
    }

    private static func parse(_ text: String, analysis a: VideoAnalysis) -> [ClipSuggestion] {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
              let data = String(text[open...close]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["clips"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard var start = (c["start"] as? NSNumber)?.doubleValue, var end = (c["end"] as? NSNumber)?.doubleValue else { return nil }
            start = a.nearestBreath(to: start) ?? start
            end = a.nearestBreath(to: end) ?? end
            start = max(0, min(start, a.duration - 5))
            end = min(a.duration, max(end, start + 8))
            if end - start > 90 { end = start + 90 }
            return ClipSuggestion(start: start, end: end,
                                  title: c["title"] as? String ?? "Clip",
                                  why: c["why"] as? String ?? "",
                                  onScreenText: c["onScreenText"] as? String ?? "",
                                  caption: c["caption"] as? String ?? "",
                                  hashtags: hashtags(c["hashtags"]))
        }
        .sorted { $0.start < $1.start }
    }

    /// Claude's hashtags, or your defaults if it didn't give any.
    private static func hashtags(_ value: Any?) -> [String] {
        let tags = DefaultHashtags.parse((value as? [String] ?? []).joined(separator: " "))
        return tags.isEmpty ? DefaultHashtags.list : tags
    }

    /// Used when Claude can't be reached: the busiest stretches, cut on breaths.
    static func fallback(_ a: VideoAnalysis) -> [ClipSuggestion] {
        let starts = [0.0] + a.breaths
        var scored: [(Double, Double, Double)] = []
        for s in starts {
            guard let e = a.breaths.first(where: { $0 - s >= 20 && $0 - s <= 40 }) ?? (s + 30 <= a.duration ? s + 30 : nil) else { continue }
            let lo = Int(s / a.hop), hi = min(a.activity.count, Int(e / a.hop))
            guard hi > lo else { continue }
            let score = (lo..<hi).map { Double(a.activity[$0]) }.reduce(0, +) / Double(hi - lo)
            scored.append((s, e, score))
        }
        var picks: [(Double, Double, Double)] = []
        for c in scored.sorted(by: { $0.2 > $1.2 }) where picks.count < 4 {
            if picks.allSatisfy({ c.1 <= $0.0 || c.0 >= $0.1 }) { picks.append(c) }
        }
        return picks.sorted { $0.0 < $1.0 }.enumerated().map { i, p in
            ClipSuggestion(start: p.0, end: p.1, title: "Busy stretch \(i + 1)", why: "One of the most active passages, cut on breaths.",
                           onScreenText: "", caption: "[Tune], live at [venue].", hashtags: DefaultHashtags.list, fromClaude: false)
        }
    }
}
