import SwiftUI

/// A month grid of posts. Tap a post to edit it; long-press and drag it to move it to another day.
struct MonthCalendarView: View {
    @Binding var editing: Post?
    @EnvironmentObject var posts: PostsStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var dropTarget: Date?
    @State private var moveError: String?

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let maxChips = 3

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let error = posts.error {
                    Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal).padding(.bottom, 6)
                }
                header
                weekdayRow
                grid
                Divider().padding(.top, 4)
                selectedDayList
            }
        }
        .refreshable { await posts.refresh() }
        .alert("Can't move that post", isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(moveError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").padding(8) }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").padding(8) }
        }
        .overlay(alignment: .trailing) {
            if !cal.isDate(month, equalTo: Date(), toGranularity: .month) || selectedDay == nil {
                Button("Today") {
                    month = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
                    selectedDay = cal.startOfDay(for: Date())
                }
                .font(.subheadline)
                .padding(.trailing, 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var weekdayRow: some View {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Grid

    /// The month's days, with nil for the blank cells before the 1st.
    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let days = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + days
    }

    private var postsByDay: [Date: [Post]] {
        let inMonth = posts.posts.filter { p in
            guard let at = p.publishAt else { return false }
            return cal.isDate(at, equalTo: month, toGranularity: .month)
        }
        return Dictionary(grouping: inMonth) { cal.startOfDay(for: $0.publishAt!) }
            .mapValues { $0.sorted { ($0.publishAt ?? .distantPast) < ($1.publishAt ?? .distantPast) } }
    }

    private var grid: some View {
        let byDay = postsByDay
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day, posts: byDay[day] ?? [])
                } else {
                    Color.clear.frame(height: 84)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func dayCell(_ day: Date, posts dayPosts: [Post]) -> some View {
        let isToday = cal.isDateInToday(day)
        let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
        let isPast = day < cal.startOfDay(for: Date())
        let isTarget = dropTarget.map { cal.isDate($0, inSameDayAs: day) } ?? false

        return VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: day))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : isPast ? Color.secondary : Color.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isToday ? Theme.accent : Color.clear))
                .frame(maxWidth: .infinity)
            ForEach(dayPosts.prefix(dayPosts.count > maxChips ? maxChips - 1 : maxChips)) { post in
                chip(post)
            }
            if dayPosts.count > maxChips {
                Text("+\(dayPosts.count - (maxChips - 1)) more")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(height: 84, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTarget ? Theme.accent.opacity(0.25) : isSelected ? Color.secondary.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTarget ? Theme.accent : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = day }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let post = posts.posts.first(where: { $0.id == id }) else { return false }
            return drop(post, on: day)
        } isTargeted: { on in
            if on { dropTarget = day } else if dropTarget.map({ cal.isDate($0, inSameDayAs: day) }) == true { dropTarget = nil }
        }
    }

    @ViewBuilder
    private func chip(_ post: Post) -> some View {
        let base = Text(post.title.isEmpty ? "Untitled" : post.title)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(post.state.color)
            .background(post.state.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                selectedDay = post.publishAt.map { cal.startOfDay(for: $0) }
                if post.isEditable { editing = post }
            }
        if post.isEditable {
            base.draggable(post.id) {
                Text(post.title.isEmpty ? "Untitled" : post.title)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(post.state.color, in: Capsule())
            }
        } else {
            base.opacity(0.7)
        }
    }

    // MARK: Selected day

    @ViewBuilder
    private var selectedDayList: some View {
        if let day = selectedDay, cal.isDate(day, equalTo: month, toGranularity: .month) {
            let dayPosts = postsByDay[cal.startOfDay(for: day)] ?? []
            VStack(alignment: .leading, spacing: 10) {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline)
                if dayPosts.isEmpty {
                    Text("Nothing on this day.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(dayPosts) { post in
                    PostRow(post: post)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { if post.isEditable { editing = post } }
                }
            }
            .padding()
        } else {
            Text("Tap a day to see its posts. Long-press a post and drag it to move it.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: Actions

    private func shiftMonth(_ by: Int) {
        guard let m = cal.date(byAdding: .month, value: by, to: month) else { return }
        month = m
        selectedDay = cal.isDate(Date(), equalTo: m, toGranularity: .month) ? cal.startOfDay(for: Date()) : nil
    }

    private func drop(_ post: Post, on day: Date) -> Bool {
        dropTarget = nil
        guard post.isEditable, let old = post.publishAt else { return false }
        if cal.isDate(old, inSameDayAs: day) { return false }
        let time = cal.dateComponents([.hour, .minute], from: old)
        let newTime = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
        if newTime < Date().addingTimeInterval(120) {
            moveError = cal.isDateInToday(day)
                ? "\(old.formatted(date: .omitted, time: .shortened)) has already passed today. Open the post to pick a later time."
                : "That day has already passed."
            return false
        }
        selectedDay = day
        Task {
            do { try await posts.move(post, toDay: day) } catch { moveError = error.localizedDescription }
        }
        return true
    }
}

extension Post.State {
    var color: Color {
        switch self {
        case .scheduled: return Theme.accent
        case .posting: return .blue
        case .posted: return .green
        case .failed: return .red
        case .notAutoPosting: return .gray
        }
    }
}
