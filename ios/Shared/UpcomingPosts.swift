import Foundation

/// The few details the home-screen widget shows, shared between the app and the widget
/// through an App Group.
struct UpcomingPost: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let format: String      // reel, photo, carousel
    let autoPost: Bool      // false = on the calendar but not posting automatically
    let failed: Bool
    /// Went out today (optional so older saved data still loads).
    var posted: Bool? = nil

    var isPosted: Bool { posted == true }
}

enum UpcomingPosts {
    static let appGroup = "group.com.chasemorrin.clipstudio"
    private static let key = "upcomingPosts"

    static func save(_ posts: [UpcomingPost]) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(posts) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> [UpcomingPost] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let posts = try? JSONDecoder().decode([UpcomingPost].self, from: data) else { return [] }
        return posts
    }
}

/// Lets the widget ask the server whether today's posts went out, even when the app isn't open.
/// The app shares its server address and login through the App Group.
enum WidgetSync {
    private static let serverKey = "widgetServer"
    private static let tokenKey = "widgetToken"

    static func saveLogin(server: URL, token: String?) {
        guard let defaults = UserDefaults(suiteName: UpcomingPosts.appGroup) else { return }
        defaults.set(server.absoluteString, forKey: serverKey)
        if let token { defaults.set(token, forKey: tokenKey) } else { defaults.removeObject(forKey: tokenKey) }
    }

    /// Marks posts that have gone out as posted. Returns the list unchanged if the server can't be reached.
    static func refresh(_ posts: [UpcomingPost]) async -> [UpcomingPost] {
        guard let defaults = UserDefaults(suiteName: UpcomingPosts.appGroup),
              let server = defaults.string(forKey: serverKey).flatMap(URL.init(string:)),
              let token = defaults.string(forKey: tokenKey) else { return posts }
        var req = URLRequest(url: server.appendingPathComponent("v1/items"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              (res as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return posts }
        var posted = Set<String>()
        for d in items {
            guard let id = d["id"] as? String else { continue }
            let ig = d["postState"] as? String
            let status = d["status"] as? String
            let yt = (d["youtube"] as? [String: Any])?["state"] as? String
            let igDone = ig == "posted" || (ig == nil && status == "posted")
            let ytPending = yt == "queued" || yt == "uploading" || yt == "failed"
            if (igDone && !ytPending) || (ig == nil && yt == "posted") { posted.insert(id) }
        }
        let updated = posts.map { p -> UpcomingPost in
            var p = p
            if posted.contains(p.id) { p.posted = true }
            return p
        }
        if updated != posts { UpcomingPosts.save(updated) }
        return updated
    }
}
