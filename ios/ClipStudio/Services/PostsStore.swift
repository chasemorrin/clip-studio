import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

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

    var isEditable: Bool { state != .posting && state != .posted }
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
        posts.filter { $0.publishAt != nil && $0.state != .posted }.sorted { ($0.publishAt ?? .distantFuture) < ($1.publishAt ?? .distantFuture) }
    }

    var recentlyPosted: [Post] {
        posts.filter { $0.state == .posted }.sorted { ($0.publishAt ?? .distantPast) > ($1.publishAt ?? .distantPast) }
    }

    /// Days that already have something scheduled (so new clips go to open days).
    var takenDays: Set<String> {
        Set(posts.filter { $0.state != .posted && $0.publishAt != nil }.compactMap { $0.publishAt.map(PostingSchedule.dayKey) })
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await APIClient.shared.request("GET", "v1/items")
            posts = (r["items"] as? [[String: Any]] ?? []).compactMap(Post.init)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Uploads a finished clip and puts it on the calendar.
    func schedule(file: URL, clip: ClipSuggestion, at date: Date, autoPost: Bool) async throws {
        let media = try await APIClient.shared.upload(file: file)
        var body: [String: Any] = [
            "title": clip.title,
            "pillar": "live",
            "format": "reel",
            "status": "edited",
            "notes": clip.why,
            "caption": clip.fullCaption,
            "date": PostingSchedule.dayKey(date),
            "publishAt": Int(date.timeIntervalSince1970),
            "media": [["key": media.key, "type": media.type]],
        ]
        if autoPost { body["autoPost"] = true }
        try await APIClient.shared.request("POST", "v1/items", json: body)
        await refresh()
    }

    func update(_ post: Post, publishAt: Date, caption: String, autoPost: Bool) async throws {
        var body: [String: Any] = [
            "publishAt": Int(publishAt.timeIntervalSince1970),
            "date": PostingSchedule.dayKey(publishAt),
            "caption": caption,
        ]
        let wasAuto = post.state == .scheduled || post.state == .failed
        if autoPost != wasAuto || (autoPost && post.state == .failed) { body["autoPost"] = autoPost }
        try await APIClient.shared.request("PATCH", "v1/items/\(post.id)", json: body)
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

/// Opens Instagram's login in a secure browser sheet and comes back to the app.
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
        let r = try await APIClient.shared.request("GET", "v1/instagram/connect")
        guard let s = r["url"] as? String, let url = URL(string: s) else {
            throw APIError(code: "bad_response", message: "The server didn't return an Instagram login link.")
        }
        return try await withCheckedThrowingContinuation { cont in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "clipstudio") { callback, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        cont.resume(throwing: APIError(code: "cancelled", message: "Instagram connection cancelled."))
                    } else {
                        cont.resume(throwing: APIError(code: "ig_failed", message: error.localizedDescription))
                    }
                    return
                }
                let items = URLComponents(url: callback ?? url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }
                switch value("status") {
                case "connected": cont.resume(returning: value("username") ?? "")
                case "cancelled": cont.resume(throwing: APIError(code: "cancelled", message: "Instagram connection cancelled."))
                default: cont.resume(throwing: APIError(code: "ig_failed", message: value("message") ?? "Instagram connection failed. Try again."))
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            self.session = auth
            if !auth.start() {
                cont.resume(throwing: APIError(code: "ig_failed", message: "Couldn't open the Instagram login. Try again."))
            }
        }
    }
}
