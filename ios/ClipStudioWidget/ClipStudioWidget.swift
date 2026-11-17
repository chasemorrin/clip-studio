import SwiftUI
import WidgetKit

private let gold = Color(red: 0.85, green: 0.64, blue: 0.25)

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let posts: [UpcomingPost]
}

struct UpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: Date(), posts: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        let posts = UpcomingPosts.load()
        completion(UpcomingEntry(date: Date(), posts: context.isPreview && posts.isEmpty ? Self.sample : posts))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        let all = UpcomingPosts.load().sorted { $0.date < $1.date }
        let now = Date()
        let cal = Calendar.current
        // Refresh at midnight (so "Today" moves) and just after each post time (so it drops off).
        var times: [Date] = [now]
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) { times.append(midnight) }
        times += all.map { $0.date.addingTimeInterval(60) }.filter { $0 > now }
        let entries = Set(times).sorted().prefix(20).map { t in
            UpcomingEntry(date: t, posts: all.filter { $0.date > t || cal.isDate($0.date, inSameDayAs: t) })
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
    }

    static let sample: [UpcomingPost] = [
        UpcomingPost(id: "1", title: "Piano solo, live", date: Date().addingTimeInterval(3 * 3600), format: "reel", autoPost: true, failed: false),
        UpcomingPost(id: "2", title: "Trio with dancers", date: Date().addingTimeInterval(2 * 86400), format: "reel", autoPost: true, failed: false),
        UpcomingPost(id: "3", title: "Studio photos", date: Date().addingTimeInterval(4 * 86400), format: "carousel", autoPost: true, failed: false),
    ]
}

struct UpcomingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpcomingEntry

    private var limit: Int {
        switch family {
        case .systemSmall, .accessoryRectangular: return 1
        case .systemMedium: return 3
        default: return 6
        }
    }

    var body: some View {
        let shown = Array(entry.posts.prefix(limit))
        Group {
            if family == .accessoryRectangular {
                lockScreen(shown.first)
            } else if shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    Spacer()
                    Text("Nothing scheduled").font(.subheadline.weight(.semibold))
                    Text("Make a clip and it'll show up here.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if family == .systemSmall, let post = shown.first {
                small(post)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
                    header
                    ForEach(shown) { row($0) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.08, green: 0.07, blue: 0.06) }
        .widgetURL(URL(string: "clipstudio://calendar"))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").foregroundStyle(gold)
            Text("Up next").font(.caption.weight(.bold)).foregroundStyle(gold)
        }
    }

    private func isToday(_ p: UpcomingPost) -> Bool { Calendar.current.isDate(p.date, inSameDayAs: entry.date) }

    private func when(_ p: UpcomingPost) -> String {
        let time = p.date.formatted(date: .omitted, time: .shortened)
        if isToday(p) { return "Today · \(time)" }
        if Calendar.current.isDateInTomorrow(p.date) { return "Tomorrow · \(time)" }
        return p.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · " + time
    }

    private func icon(_ p: UpcomingPost) -> String {
        if p.failed { return "exclamationmark.triangle.fill" }
        switch p.format {
        case "carousel": return "square.stack.fill"
        case "photo": return "photo.fill"
        default: return "play.rectangle.fill"
        }
    }

    private func small(_ p: UpcomingPost) -> some View {
        let today = isToday(p)
        return VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            if today {
                Text("TODAY").font(.caption2.weight(.heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(gold, in: Capsule())
            }
            Text(p.title.isEmpty ? "Untitled post" : p.title)
                .font(.headline).foregroundStyle(.white).lineLimit(3)
            Label(today ? p.date.formatted(date: .omitted, time: .shortened) : when(p), systemImage: icon(p))
                .font(.caption).foregroundStyle(p.failed ? .orange : .white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ p: UpcomingPost) -> some View {
        let today = isToday(p)
        return HStack(spacing: 8) {
            Image(systemName: icon(p))
                .font(.caption)
                .foregroundStyle(today ? Color.black : (p.failed ? Color.orange : gold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title.isEmpty ? "Untitled post" : p.title)
                    .font(.subheadline.weight(today ? .bold : .semibold))
                    .foregroundStyle(today ? Color.black : Color.white)
                    .lineLimit(1)
                Text(when(p) + (p.failed ? " · didn't post" : p.autoPost ? "" : " · not auto-posting"))
                    .font(.caption2)
                    .foregroundStyle(today ? Color.black.opacity(0.7) : Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, today ? 8 : 0)
        .padding(.vertical, today ? 5 : 0)
        .background(today ? gold : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func lockScreen(_ p: UpcomingPost?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Up next", systemImage: "calendar").font(.caption2.weight(.bold))
            if let p {
                Text(p.title.isEmpty ? "Untitled post" : p.title).font(.headline).lineLimit(1)
                Text(when(p)).font(.caption).lineLimit(1)
            } else {
                Text("Nothing scheduled").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct ClipStudioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpcomingPosts", provider: UpcomingProvider()) { entry in
            UpcomingWidgetView(entry: entry)
        }
        .configurationDisplayName("Upcoming posts")
        .description("Your next scheduled posts. Today's is highlighted.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}
