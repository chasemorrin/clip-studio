import AuthenticationServices
import Foundation
import SwiftUI
import UIKit
import WidgetKit

struct MediaRef: Hashable {
    let key: String
    let type: String
    var isVideo: Bool { type == "video" }
}

/// A post on the server's calendar.
struct Post: Identifiable, Hashable {
    let id: String
    var title: String
    var caption: String
    var date: String
    var status: String
    var format: String
    var publishAt: Date?
    var postState: String?
    var postError: String?
    var permalink: URL?
    var media: [MediaRef] = []
    var plan: ClipPlan?
    var youtube = YouTubeStatus()

    /// YouTube Shorts posting, tracked separately from Instagram.
    struct YouTubeStatus: Hashable {
        enum State { case off, scheduled, uploading, posted, failed }
        var state: State = .off
        var title: String?
        var privacy: String?
        var error: String?
        var url: URL?

        init() {}
        init(_ d: [String: Any]?) {
            guard let d else { return }
            switch d["state"] as? String {
            case "queued": state = .scheduled
            case "uploading": state = .uploading
            case "posted": state = .posted
            case "failed": state = .failed
            default: state = .off
            }
            title = d["title"] as? String
            privacy = d["privacy"] as? String
            error = d["error"] as? String
            url = (d["url"] as? String).flatMap(URL.init(string:))
        }

        var isOn: Bool { state != .off }
        /// Still has work to do (or failed and could be retried).
        var isPending: Bool { state == .scheduled || state == .uploading || state == .failed }
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        title = d["title"] as? String ?? ""
        caption = d["caption"] as? String ?? ""
        date = d["date"] as? String ?? ""
        status = d["status"] as? String ?? "idea"
        format = d["format"] as? String ?? "reel"
        publishAt = (d["publishAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        postState = d["postState"] as? String
        postError = d["postError"] as? String
        permalink = (d["permalink"] as? String).flatMap(URL.init(string:))
        media = (d["media"] as? [[String: Any]] ?? []).compactMap { m in
            (m["key"] as? String).map { MediaRef(key: $0, type: m["type"] as? String ?? "video") }
        }
        plan = ClipPlan(json: d["plan"])
        youtube = YouTubeStatus(d["youtube"] as? [String: Any])
    }

    enum State { case scheduled, posting, posted, failed, notAutoPosting }

    var state: State {
        switch postState {
        case "queued": return .scheduled
        case "children", "publishing": return .posting
        case "posted": return .posted
        case "failed": return .failed
        default: return status == "posted" ? .posted : .notAutoPosting
        }
    }

    /// Everything that was going to post has posted (Instagram and, if it's on, YouTube).
    var isFullyPosted: Bool {
        switch state {
        case .posted: return !youtube.isPending
        case .notAutoPosting: return youtube.state == .posted
        default: return false
        }
    }

    var isEditable: Bool { !isFullyPosted && state != .posting && youtube.state != .uploading }

    var hasVideo: Bool { media.contains(where: \.isVideo) }

    /// Something failed on either platform and can be retried.
    var canRetry: Bool { state == .failed || youtube.state == .failed }
}

/// Your posting days and time, chosen in Settings.
enum PostingSchedule {
    /// Calendar weekday numbers: 1 = Sunday … 7 = Saturday. Default Mon, Wed, Fri.
    static var days: Set<Int> {
        get {
            let raw = UserDefaults.standard.string(forKey: "postDays") ?? "2,4,6"
            return Set(raw.split(separator: ",").compactMap { Int($0) })
        }
        set { UserDefaults.standard.set(newValue.sorted().map(String.init).joined(separator: ","), forKey: "postDays") }
    }

    /// Minutes after midnight. Default 6:30 PM.
    static var minutes: Int {
        get { UserDefaults.standard.object(forKey: "postMinutes") as? Int ?? 18 * 60 + 30 }
        set { UserDefaults.standard.set(newValue, forKey: "postMinutes") }
    }

    /// The next `count` posting slots on days that don't already have a scheduled post.
    static func nextSlots(_ count: Int, taken: Set<String>, after start: Date = Date()) -> [Date] {
        let cal = Calendar.current
        let days = self.days.isEmpty ? Set([2, 4, 6]) : self.days
        var slots: [Date] = []
        var takenDays = taken
        var day = cal.startOfDay(for: start)
        for _ in 0..<400 where slots.count < count {
            if days.contains(cal.component(.weekday, from: day)),
               let slot = cal.date(byAdding: .minute, value: minutes, to: day),
               slot > start.addingTimeInterval(10 * 60),
               !takenDays.contains(dayKey(slot)) {
                slots.append(slot)
                takenDays.insert(dayKey(slot))
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return slots
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

@MainActor
final class PostsStore: ObservableObject {
    @Published private(set) var posts: [Post] = []
    @Published var loading = false
    @Published var error: String?

    var upcoming: [Post] {
        posts.filter { $0.publishAt != nil && !$0.isFullyPosted }.sorted { ($0.publishAt ?? .distantFuture) < ($1.publishAt ?? .distantFuture) }
    }

    var recentlyPosted: [Post] {
        posts.filter { $0.isFullyPosted }.sorted { ($0.publishAt ?? .distantPast) > ($1.publishAt ?? .distantPast) }
    }

    /// Days that already have something scheduled (so new clips go to open days).
    var takenDays: Set<String> {
        Set(posts.filter { !$0.isFullyPosted && $0.publishAt != nil }.compactMap { $0.publishAt.map(PostingSchedule.dayKey) })
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await APIClient.shared.request("GET", "v1/items")
            posts = (r["items"] as? [[String: Any]] ?? []).compactMap(Post.init)
            error = nil
            updateWidget()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Hands the home-screen widget the next posts.
    private func updateWidget() {
        let today = Calendar.current.startOfDay(for: Date())
        let next = upcoming.filter { ($0.publishAt ?? .distantPast) >= today }.prefix(10).map { p in
            UpcomingPost(id: p.id, title: p.title, date: p.publishAt ?? Date(), format: p.format,
                         autoPost: p.state == .scheduled || p.state == .posting || p.youtube.state == .scheduled || p.youtube.state == .uploading,
                         failed: p.state == .failed || p.youtube.state == .failed)
        }
        let list = Array(next)
        if list != UpcomingPosts.load() {
            UpcomingPosts.save(list)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Uploads a finished clip and puts it on the calendar. Returns the new post's id.
    @discardableResult
    func schedule(file: URL, clip: ClipSuggestion, at date: Date, autoPost: Bool, youtube: Bool = false, youtubeTitle: String? = nil,
                  sourceAssetID: String? = nil) async throws -> String {
        let media = try await APIClient.shared.upload(file: file)
        return try await create(title: clip.title, caption: clip.fullCaption, notes: clip.why, format: "reel",
                                media: [media], at: date, autoPost: autoPost, youtube: youtube, youtubeTitle: youtubeTitle,
                                plan: sourceAssetID.flatMap { ClipPlan(clip: clip, assetId: $0).json })
    }

    /// Replaces a scheduled clip's video after re-editing it, and removes the old file.
    func replaceClip(_ post: Post, file: URL, clip: ClipSuggestion, sourceAssetID: String?) async throws {
        let media = try await APIClient.shared.upload(file: file)
        var body: [String: Any] = [
            "title": clip.title,
            "caption": clip.fullCaption,
            "media": [["key": media.key, "type": media.type]],
        ]
        if let sourceAssetID, let plan = ClipPlan(clip: clip, assetId: sourceAssetID).json { body["plan"] = plan }
        try await APIClient.shared.request("PATCH", "v1/items/\(post.id)", json: body)
        for old in post.media where old.key != media.key {
            _ = try? await APIClient.shared.request("DELETE", "v1/media/\(old.key)")
        }
        await refresh()
    }

    /// A temporary link to preview a post's file.
    func previewURL(for media: MediaRef) async throws -> URL {
        let r = try await APIClient.shared.request("GET", "v1/media-url/\(media.key)")
        guard let s = r["url"] as? String, let url = URL(string: s) else {
            throw APIError(code: "bad_response", message: "the server's answer didn't include a link")
        }
        return url
    }

    /// Puts already-uploaded media on the calendar. Returns the new post's id.
    @discardableResult
    func create(title: String, caption: String, notes: String = "", format: String,
                media: [(key: String, type: String)], at date: Date, autoPost: Bool, youtube: Bool = false, youtubeTitle: String? = nil,
                plan: [String: Any]? = nil) async throws -> String {
        var body: [String: Any] = [
            "title": title,
            "pillar": "live",
            "format": format,
            "status": "edited",
            "notes": notes,
            "caption": caption,
            "date": PostingSchedule.dayKey(date),
            "publishAt": Int(date.timeIntervalSince1970),
            "media": media.map { ["key": $0.key, "type": $0.type] },
        ]
        if autoPost { body["autoPost"] = true }
        if youtube { body["youtube"] = true }
        if let youtubeTitle, !youtubeTitle.isEmpty { body["ytTitle"] = String(youtubeTitle.prefix(100)) }
        if let plan { body["plan"] = plan }
        let r = try await APIClient.shared.request("POST", "v1/items", json: body)
        await refresh()
        return (r["item"] as? [String: Any])?["id"] as? String ?? ""
    }

    /// True while something is posting or due within two minutes, so the Calendar should check often.
    var somethingIsHappening: Bool {
        let soon = Date().addingTimeInterval(120)
        return posts.contains {
            $0.state == .posting || $0.youtube.state == .uploading
                || (($0.state == .scheduled || $0.youtube.state == .scheduled) && ($0.publishAt ?? .distantFuture) <= soon)
        }
    }

    /// Start publishing right away instead of waiting for the scheduled time.
    /// Posts right away. By default: Instagram, plus YouTube when it's switched on for the post.
    func postNow(id: String, instagram: Bool? = nil, youtube: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let instagram { body["instagram"] = instagram }
        if let youtube { body["youtube"] = youtube }
        try await APIClient.shared.request("POST", "v1/items/\(id)/publish-now", json: body)
        await refresh()
    }

    func postNow(_ post: Post) async {
        do { try await postNow(id: post.id) } catch { self.error = error.localizedDescription }
    }

    func update(_ post: Post, title: String, publishAt: Date, caption: String, autoPost: Bool,
                youtube: Bool? = nil, youtubeTitle: String? = nil) async throws {
        var body: [String: Any] = [
            "title": title,
            "publishAt": Int(publishAt.timeIntervalSince1970),
            "date": PostingSchedule.dayKey(publishAt),
            "caption": caption,
        ]
        let wasAuto = post.state == .scheduled || post.state == .failed
        if post.state != .posted, autoPost != wasAuto || (autoPost && post.state == .failed) { body["autoPost"] = autoPost }
        if let youtube, post.youtube.state != .posted, youtube != post.youtube.isOn || (youtube && post.youtube.state == .failed) {
            body["youtube"] = youtube
        }
        if let youtubeTitle { body["ytTitle"] = String(youtubeTitle.prefix(100)) }
        try await APIClient.shared.request("PATCH", "v1/items/\(post.id)", json: body)
        await refresh()
    }

    /// Moves a post to another day, keeping its time of day. Shows the move right away,
    /// then saves it (and puts it back if saving fails).
    func move(_ post: Post, toDay day: Date) async throws {
        guard let old = post.publishAt else { return }
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute, .second], from: old)
        guard let new = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0,
                                 of: cal.startOfDay(for: day)) else { return }
        guard !cal.isDate(new, inSameDayAs: old) else { return }
        if let i = posts.firstIndex(where: { $0.id == post.id }) {
            posts[i].publishAt = new
            posts[i].date = PostingSchedule.dayKey(new)
        }
        do {
            try await APIClient.shared.request("PATCH", "v1/items/\(post.id)", json: [
                "publishAt": Int(new.timeIntervalSince1970),
                "date": PostingSchedule.dayKey(new),
            ])
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Upcoming posts already on this day (not yet posted), leaving out one post (the one being edited).
    func conflicts(on day: Date, excluding id: String? = nil) -> [Post] {
        upcoming.filter { p in
            p.id != id && p.state != .posted && p.publishAt.map { Calendar.current.isDate($0, inSameDayAs: day) } == true
        }
    }

    struct PushMove: Identifiable {
        let post: Post
        let to: Date
        var id: String { post.id }
    }

    /// What happens if a new post takes `day`: the posts on that day move to the next open posting slot,
    /// and any post in the way moves along too, so every post keeps its own day and its order.
    func pushBackPlan(from day: Date, excluding id: String? = nil) -> [PushMove] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let later = upcoming.filter { $0.id != id && ($0.publishAt ?? .distantPast) >= start }
        var taken: Set<String> = [PostingSchedule.dayKey(day)]
        // Posts that are publishing right now stay put; keep their days free of others.
        for p in later where !p.isEditable { if let at = p.publishAt { taken.insert(PostingSchedule.dayKey(at)) } }
        var moves: [PushMove] = []
        for p in later where p.isEditable {
            guard let at = p.publishAt else { continue }
            let key = PostingSchedule.dayKey(at)
            if taken.contains(key) {
                guard let slot = PostingSchedule.nextSlots(1, taken: taken, after: max(at, Date())).first else { continue }
                taken.insert(PostingSchedule.dayKey(slot))
                moves.append(PushMove(post: p, to: slot))
            } else {
                taken.insert(key)
            }
        }
        return moves
    }

    /// After a new post is saved on `day`: pushes the others back if asked. A failure here is shown
    /// on the Calendar rather than thrown, because the new post itself did get scheduled.
    func pushBackAfterScheduling(_ on: Bool, day: Date, newID: String) async {
        guard on, !conflicts(on: day, excluding: newID).isEmpty else { return }
        do {
            try await pushBack(from: day, excluding: newID)
        } catch {
            self.error = "Your post is scheduled, but moving the other posts back didn't finish: \(error.localizedDescription)"
        }
    }

    /// Applies `pushBackPlan`.
    func pushBack(from day: Date, excluding id: String? = nil) async throws {
        let moves = pushBackPlan(from: day, excluding: id)
        do {
            for m in moves {
                try await APIClient.shared.request("PATCH", "v1/items/\(m.post.id)", json: [
                    "publishAt": Int(m.to.timeIntervalSince1970),
                    "date": PostingSchedule.dayKey(m.to),
                ])
            }
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    func setAutoPost(_ post: Post, _ on: Bool) async {
        do {
            try await APIClient.shared.request("PATCH", "v1/items/\(post.id)", json: ["autoPost": on])
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func retry(_ post: Post) async {
        do {
            try await APIClient.shared.request("POST", "v1/items/\(post.id)/retry")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ post: Post) async {
        do {
            try await APIClient.shared.request("DELETE", "v1/items/\(post.id)")
            posts.removeAll { $0.id == post.id }
            updateWidget()
        } catch { self.error = error.localizedDescription }
    }
}

extension ClipSuggestion {
    /// Caption plus hashtags, as it will appear on Instagram.
    var fullCaption: String {
        let tags = hashtags.map { "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.joined(separator: " ")
        return tags.isEmpty ? caption : "\(caption)\n\n\(tags)"
    }
}

/// Opens Instagram's (or Google's, for YouTube) login in a secure browser sheet and comes back to the app.
@MainActor
final class InstagramConnector: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    /// Returns the connected Instagram username.
    func connect() async throws -> String {
        try await connect(path: "v1/instagram/connect", service: "Instagram", valueKey: "username")
    }

    /// Returns the connected YouTube channel's name.
    func connectYouTube() async throws -> String {
        try await connect(path: "v1/youtube/connect", service: "YouTube", valueKey: "channel")
    }

    private func connect(path: String, service: String, valueKey: String) async throws -> String {
        let r = try await APIClient.shared.request("GET", path)
        guard let s = r["url"] as? String, let url = URL(string: s) else {
            throw APIError(code: "bad_response", message: "The server didn't return a \(service) login link.")
        }
        return try await withCheckedThrowingContinuation { cont in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "clipstudio") { callback, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        cont.resume(throwing: APIError(code: "cancelled", message: "\(service) connection cancelled."))
                    } else {
                        cont.resume(throwing: APIError(code: "connect_failed", message: error.localizedDescription))
                    }
                    return
                }
                let items = URLComponents(url: callback ?? url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }
                switch value("status") {
                case "connected": cont.resume(returning: value(valueKey) ?? "")
                case "cancelled": cont.resume(throwing: APIError(code: "cancelled", message: "\(service) connection cancelled."))
                default: cont.resume(throwing: APIError(code: "connect_failed", message: value("message") ?? "\(service) connection failed. Try again."))
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            self.session = auth
            if !auth.start() {
                cont.resume(throwing: APIError(code: "connect_failed", message: "Couldn't open the \(service) login. Try again."))
            }
        }
    }
}
