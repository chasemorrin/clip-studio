import SwiftUI
import UIKit

/// "Post on" with a calendar that puts a dot under every day that already has a post,
/// plus a time picker. Tapping the date opens the calendar; picking a day closes it.
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
        VStack(spacing: 0) {
            HStack {
                Text("Post on")
                Spacer()
                Button {
                    withAnimation(.snappy) { showCalendar.toggle() }
                } label: {
                    Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .foregroundStyle(showCalendar ? Theme.accent : Color.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            if showCalendar {
                PostCalendar(date: $date, earliest: earliest, marked: markedDays) {
                    withAnimation(.snappy) { showCalendar = false }
                }
                .padding(.top, 8)
                Text("Dots mark days that already have a post.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .onChange(of: date) { _, d in if d < earliest { date = earliest } }
    }
}

/// UIKit's calendar, which can draw a dot under a day.
struct PostCalendar: UIViewRepresentable {
    @Binding var date: Date
    var earliest: Date
    var marked: Set<String>
    var onPick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar.current
        view.locale = Locale.current
        view.fontDesign = .rounded
        view.tintColor = UIColor(Theme.accent)
        view.availableDateRange = DateInterval(start: Calendar.current.startOfDay(for: earliest), end: .distantFuture)
        view.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        selection.selectedDate = Calendar.current.dateComponents([.year, .month, .day], from: date)
        view.selectionBehavior = selection
        view.visibleDateComponents = Calendar.current.dateComponents([.year, .month], from: date)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        let old = context.coordinator.parent.marked
        context.coordinator.parent = self
        let changed = old.symmetricDifference(marked)
        if !changed.isEmpty {
            view.reloadDecorations(forDateComponents: changed.compactMap(Self.components), animated: true)
        }
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate {
            let want = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if selection.selectedDate != want { selection.setSelected(want, animated: false) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? 340
        let fitted = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fitted.height)
    }

    private static func components(_ key: String) -> DateComponents? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(calendar: Calendar.current, year: parts[0], month: parts[1], day: parts[2])
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: PostCalendar
        init(_ parent: PostCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            var c = dateComponents
            c.calendar = Calendar.current
            guard let day = c.date, parent.marked.contains(PostingSchedule.dayKey(day)) else { return nil }
            return .default(color: UIColor(Theme.accent), size: .large)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dc = dateComponents else { return }
            let cal = Calendar.current
            let time = cal.dateComponents([.hour, .minute], from: parent.date)
            var c = DateComponents(year: dc.year, month: dc.month, day: dc.day, hour: time.hour, minute: time.minute)
            c.calendar = cal
            guard let picked = c.date else { return }
            parent.date = max(picked, parent.earliest)
            parent.onPick()
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            guard var c = dateComponents else { return false }
            c.calendar = Calendar.current
            guard let d = c.date else { return false }
            return d >= Calendar.current.startOfDay(for: parent.earliest)
        }
    }
}
