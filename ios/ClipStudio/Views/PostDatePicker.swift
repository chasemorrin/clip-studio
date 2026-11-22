import SwiftUI

/// "Post on": tap the date for a small calendar that floats over the screen (like the system one),
/// with a gold dot under every day that already has a post. The time picker sits next to it.
struct PostDateField: View {
    @Binding var date: Date
    var earliest: Date = Date()
    /// The post being edited, so its own day isn't marked.
    var excluding: String? = nil
    @EnvironmentObject var posts: PostsStore
    @State private var showCalendar = false

    private var markedDays: Set<String> {
        Set(posts.upcoming.filter { $0.id != excluding }.compactMap { $0.publishAt.map(PostingSchedule.dayKey) })
    }

    var body: some View {
        HStack {
            Text("Post on")
            Spacer()
            Button {
                showCalendar = true
            } label: {
                Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .foregroundStyle(showCalendar ? Theme.accent : Color.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCalendar, arrowEdge: .top) {
                MiniCalendar(date: $date, earliest: earliest, marked: markedDays) { showCalendar = false }
                    .padding(14)
                    .frame(width: 330)
                    .presentationCompactAdaptation(.popover)
            }
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .onChange(of: date) { _, d in if d < earliest { date = earliest } }
    }
}

/// A compact month calendar. Days with a post get a small dot inside their cell, so rows don't grow.
struct MiniCalendar: View {
    @Binding var date: Date
    var earliest: Date
    var marked: Set<String>
    var onPick: () -> Void
    @State private var month: Date

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    init(date: Binding<Date>, earliest: Date, marked: Set<String>, onPick: @escaping () -> Void) {
        _date = date
        self.earliest = earliest
        self.marked = marked
        self.onPick = onPick
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: date.wrappedValue)?.start ?? Date())
    }

    private var firstMonth: Date { cal.dateInterval(of: .month, for: earliest)?.start ?? earliest }

    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 30) }
                    .disabled(month <= firstMonth)
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 30) }
            }
            .font(.body.weight(.semibold))
            .tint(Theme.accent)

            HStack(spacing: 0) {
                let symbols = cal.veryShortStandaloneWeekdaySymbols
                let first = cal.firstWeekday - 1
                ForEach(Array((symbols[first...] + symbols[..<first]).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let selected = cal.isDate(day, inSameDayAs: date)
        let isToday = cal.isDateInToday(day)
        let disabled = day < cal.startOfDay(for: earliest)
        let dot = marked.contains(PostingSchedule.dayKey(day))
        let color: Color = selected ? .black : disabled ? Color.secondary.opacity(0.45) : isToday ? Theme.accent : .primary
        return Button { pick(day) } label: {
            ZStack(alignment: .bottom) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(selected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(selected ? Theme.accent : Color.clear))
                    .frame(maxHeight: .infinity, alignment: .top)
                if dot {
                    Circle().fill(Theme.accent).frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func shift(_ by: Int) {
        if let m = cal.date(byAdding: .month, value: by, to: month) { month = m }
    }

    private func pick(_ day: Date) {
        let time = cal.dateComponents([.hour, .minute], from: date)
        let picked = cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
        date = max(picked, earliest)
        onPick()
    }
}
