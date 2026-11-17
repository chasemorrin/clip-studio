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
