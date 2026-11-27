import SwiftUI

/// A month grid of posts. Tap a day to list its posts below (tap one there to edit it);
/// long-press a post in the grid and drag it to move it to another day.
struct MonthCalendarView: View {
    @Binding var editing: Post?
    /// Owned by the Calendar screen so its + button knows the day.
    @Binding var selectedDay: Date?
    @EnvironmentObject var posts: PostsStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var dropTarget: Date?
    @State private var moveError: String?
    @State private var pendingDrop: PendingDrop?

    /// A post dropped on a day that already has one, waiting for "push back" or "keep both".
    struct PendingDrop: Identifiable {
        let id = UUID()
        let post: Post
        let day: Date
    }
    @State private var pagePost: String?

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let maxChips = 2
    private let cellHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            if let error = posts.error {
                Text(error).foregroundStyle(.red).font(.caption).lineLimit(2).padding(.horizontal).padding(.bottom, 4)
            }
            header
            weekdayRow
            grid
            Divider().padding(.top, 2)
            selectedDayList
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .alert("Can't move that post", isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(moveError ?? "")
        }
        .confirmationDialog(pendingDrop.map { "\($0.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) already has a post" } ?? "",
                            isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
                            titleVisibility: .visible, presenting: pendingDrop) { p in
            Button("Push the other posts back") {
                Task {
                    do {
                        try await posts.move(p.post, toDay: p.day)
                        try await posts.pushBack(from: p.day, excluding: p.post.id)
                    } catch { moveError = error.localizedDescription }
                }
            }
            Button("Keep both on this day") {
                Task { do { try await posts.move(p.post, toDay: p.day) } catch { moveError = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Pushing back moves that day's post, and any after it that are in the way, to your next open posting slots.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 40, height: 36)
            }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
            Spacer()
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 40, height: 36)
            }
        }
        .overlay(alignment: .trailing) {
            if !cal.isDate(month, equalTo: Date(), toGranularity: .month) || selectedDay == nil {
                Button("Today") {
                    month = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
                    selectedDay = cal.startOfDay(for: Date())
                }
                .font(.subheadline)
                .padding(.trailing, 48)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
        .padding(.vertical, 3)
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
                    Color.clear.frame(height: cellHeight)
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
                .frame(width: 20, height: 20)
                .background(Circle().fill(isToday ? Theme.accent : Color.clear))
                .frame(maxWidth: .infinity)
            ForEach(dayPosts.prefix(dayPosts.count > maxChips ? maxChips - 1 : maxChips)) { post in
                chip(post)
            }
            if dayPosts.count > maxChips {
                Text("+\(dayPosts.count - (maxChips - 1)) more")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(height: cellHeight, alignment: .top)
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
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(post.displayColor)
            .background(post.displayColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        if post.isEditable {
            base.draggable(post.id) {
                Text(post.title.isEmpty ? "Untitled" : post.title)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(post.displayColor, in: Capsule())
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if dayPosts.count > 1 {
                        let n = (dayPosts.firstIndex { $0.id == pagePost } ?? 0) + 1
                        Label("\(n) of \(dayPosts.count)", systemImage: "chevron.up.chevron.down")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                if dayPosts.isEmpty {
                    Text("Nothing on this day.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                } else {
                    // One post per page: swipe up or down to snap to the next.
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(dayPosts) { post in
                                PostRow(post: post)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                    .onTapGesture { if post.isEditable { editing = post } }
                                    .contextMenu { PostMenu(post: post, editing: $editing) }
                                    .padding(.horizontal)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .containerRelativeFrame(.vertical)
                                    .id(post.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $pagePost)
                    .id(cal.startOfDay(for: day))  // start at the first post when the day changes
                }
            }
            .padding(.top, 8)
            .onChange(of: selectedDay) { _, _ in pagePost = nil }
        } else {
            Text("Tap a day to see its posts. Long-press a post and drag it to another day to move it.")
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
        if !posts.conflicts(on: day, excluding: post.id).isEmpty {
            pendingDrop = PendingDrop(post: post, day: day)
            return true
        }
        Task {
            do { try await posts.move(post, toDay: day) } catch { moveError = error.localizedDescription }
        }
        return true
    }
}

extension Post {
    /// The Instagram status color, or YouTube's for a YouTube-only post.
    var displayColor: Color {
        if isIdea { return .gray }
        guard state == .notAutoPosting, youtube.isOn else { return state.color }
        switch youtube.state {
        case .failed: return .red
        case .uploading: return .blue
        case .posted: return .green
        default: return Theme.accent
        }
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
