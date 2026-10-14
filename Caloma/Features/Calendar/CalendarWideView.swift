import SwiftUI

/// The iPad calendar: a week grid, or the month and a day side by side. The family filters sit
/// in the app's sidebar under the tabs (`CalendarSidebarFilters`), with the same filters in a
/// menu here for when the sidebar is closed.
struct CalendarWideView: View {
    var data: CalendarData
    @Binding var day: Date
    @Binding var mode: CalendarView.Mode
    var visible: (EventRecord) -> Bool
    var onNew: (NewEventRequest) -> Void
    var onOpen: (OccurrenceRef) -> Void

    @Environment(\.accent) private var accent
    private let apple = AppleCalendar.shared
    private let filter = CalendarFilter.shared
    private var showChores: Bool { filter.showChores }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if mode == .week {
                    WeekGrid(data: data, week: CalendarMath.week(containing: day), visible: visible, showChores: showChores, onNew: onNew, onOpen: onOpen)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        MonthGrid(day: $day, data: data, visible: visible, cellHeight: 64) { date in onNew(NewEventRequest(day: date)) }
                            .frame(maxWidth: 520)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                    .font(.title3.bold())
                                DayAgenda(
                                    day: day,
                                    data: data,
                                    occurrences: data.occurrences(on: day, where: visible),
                                    appleEvents: apple.events(from: day, through: day),
                                    chores: showChores ? data.chores(on: day) : [],
                                    homeTasks: showChores ? data.homeTasksDue(on: day) : [],
                                    onOpen: onOpen,
                                    onNew: { onNew(NewEventRequest(day: day)) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        let week = CalendarMath.week(containing: day)
        // The small caption sits above, so the title, Week / Month and the buttons all center
        // on one line.
        return VStack(alignment: .leading, spacing: 2) {
            Text(mode == .week ? "WEEK OF \(week.first?.formatted(.dateTime.month(.wide).day()).uppercased() ?? "")" : "MONTH")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                Text(day.formatted(.dateTime.month(.wide).year()))
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .fixedSize()
                // Week / Month fills the space between the title and the buttons.
                Picker("View", selection: $mode.animation(.snappy)) {
                    ForEach(CalendarView.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 160, maxWidth: .infinity)
                .padding(.horizontal, 12)
                // ‹ Today › together, the filter, then New Event.
                HStack(spacing: 6) {
                    Button {
                        move(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel(mode == .week ? "Previous week" : "Previous month")
                    Button {
                        withAnimation(.snappy) { day = Calendar.current.startOfDay(for: .now) }
                    } label: {
                        Text("Today")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    Button {
                        move(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel(mode == .week ? "Next week" : "Next month")
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                filterMenu
                Button {
                    onNew(NewEventRequest(day: day))
                } label: {
                    Label("New Event", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.leading, 12)
                        .padding(.trailing, 16)
                        .frame(height: 40)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.tint(accent).interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The sidebar's filters, for when the sidebar is closed.
    private var filterMenu: some View {
        Menu {
            Section("Family") {
                Toggle("Everyone", isOn: Binding(get: { filter.isShown("everyone") }, set: { _ in filter.toggle("everyone") }))
                ForEach(data.members) { member in
                    Toggle(member.name, isOn: Binding(get: { filter.isShown(member.id.uuidString) }, set: { _ in filter.toggle(member.id.uuidString) }))
                }
            }
            Toggle("Chores & Home Care", isOn: Binding(get: { filter.showChores }, set: { filter.showChores = $0 }))
        } label: {
            Image(systemName: filter.hidden.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show on calendar")
    }

    private func move(by step: Int) {
        withAnimation(.snappy) {
            let component: Calendar.Component = mode == .week ? .weekOfYear : .month
            day = Calendar.current.date(byAdding: component, value: step, to: day) ?? day
        }
    }
}

/// A week as columns of hours, events placed by time and colored by who's going. All-day
/// events, home care and chores counts sit in a row along the top.
struct WeekGrid: View {
    var data: CalendarData
    var week: [Date]
    var visible: (EventRecord) -> Bool
    var showChores: Bool
    var onNew: (NewEventRequest) -> Void
    var onOpen: (OccurrenceRef) -> Void

    @Environment(\.accent) private var accent
    private let apple = AppleCalendar.shared
    private let hourHeight: CGFloat = 52
    /// The whole day, midnight to midnight. It opens scrolled to the morning (or to now).
    private let firstHour = 0
    private let lastHour = 24
    private let gutter: CGFloat = 52

    var body: some View {
        let calendar = Calendar.current
        let from = week.first ?? .now
        let through = week.last ?? .now
        let occurrences = data.occurrences(from: from, through: through, where: visible)
        let appleEvents = apple.events(from: from, through: through)
        VStack(spacing: 0) {
            // Day names.
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(week, id: \.self) { date in
                    let today = calendar.isDateInToday(date)
                    HStack(spacing: 6) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated)))
                            .foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.day()))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .frame(minWidth: 28, minHeight: 28)
                            .background { if today { Capsule().fill(accent) } }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)
            Divider()
            // All day.
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                ForEach(week, id: \.self) { date in
                    VStack(spacing: 3) {
                        ForEach(allDay(on: date, occurrences: occurrences)) { occurrence in
                            Button {
                                onOpen(OccurrenceRef(eventID: occurrence.event.id, day: date))
                            } label: {
                                chip(occurrence.event.title, color: data.color(for: occurrence.event), dashed: false)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(appleEvents.filter { $0.isAllDay && calendar.isDate($0.start, inSameDayAs: date) }) { event in
                            chip(event.title, color: event.color, dashed: false)
                        }
                        if showChores {
                            ForEach(data.homeTasksDue(on: date)) { task in
                                chip(task.name, color: calendar.startOfDay(for: task.nextDue) < calendar.startOfDay(for: .now) ? Brand.late : Brand.waiting, dashed: true)
                            }
                            let count = data.chores(on: date).count
                            if count > 0 {
                                chip("\(count) chores", color: .secondary, dashed: true)
                            }
                        }
                    }
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    // Tapping the empty part of the row starts an all-day event that day.
                    .onTapGesture {
                        onNew(NewEventRequest(day: date, start: calendar.startOfDay(for: date), allDay: true))
                    }
                    .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
                }
            }
            .frame(minHeight: 50)
            // As tall as its tallest day, so each day's cell fills the row (and can be tapped)
            // without taking the hours' room.
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            // Hours.
            ScrollViewReader { scroller in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(firstHour..<lastHour, id: \.self) { hour in
                            Text(hourLabel(hour))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                                .padding(.trailing, 8)
                                .offset(y: -7)
                                .opacity(hour == firstHour ? 0 : 1)
                                .id(hour)
                        }
                    }
                    ForEach(week, id: \.self) { date in
                        dayColumn(date, occurrences: timed(on: date, occurrences: occurrences), apple: appleEvents.filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: date) })
                    }
                }
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(firstHour..<lastHour, id: \.self) { _ in
                            VStack(spacing: 0) {
                                Rectangle().fill(Color(.separator)).frame(height: 0.5)
                                Spacer(minLength: 0)
                            }
                            .frame(height: hourHeight)
                        }
                    }
                    .padding(.leading, gutter)
                }
            }
            .task {
                // After the grid is laid out, or the scroll has nowhere to go.
                try? await Task.sleep(for: .milliseconds(50))
                scroller.scrollTo(openingHour, anchor: .top)
            }
            .onChange(of: week.first) { _, _ in
                withAnimation(.snappy) { scroller.scrollTo(openingHour, anchor: .top) }
            }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .clipShape(.rect(cornerRadius: 22))
    }

    /// 7 AM, or an hour before now when the week has today in it.
    private var openingHour: Int {
        let calendar = Calendar.current
        guard week.contains(where: { calendar.isDateInToday($0) }) else { return 7 }
        return min(max(calendar.component(.hour, from: .now) - 1, 0), 17)
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return hour == 12 ? "Noon" : date.formatted(.dateTime.hour())
    }

    private func allDay(on date: Date, occurrences: [EventOccurrence]) -> [EventOccurrence] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return occurrences.filter { $0.event.isAllDay && $0.start < end && $0.end > start }
    }

    private func timed(on date: Date, occurrences: [EventOccurrence]) -> [EventOccurrence] {
        occurrences.filter { !$0.event.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: date) }
    }

    private func chip(_ title: String, color: Color, dashed: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .foregroundStyle(dashed ? color : color.mix(with: .primary, by: 0.25))
            .background {
                if dashed {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.16))
                }
            }
    }

    private struct Placed: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var start: Date
        var end: Date
        var color: Color
        var ref: OccurrenceRef?
        var lane = 0
        var lanes = 1
    }

    private func dayColumn(_ date: Date, occurrences: [EventOccurrence], apple: [AppleEvent]) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: date) ?? date
        var items: [Placed] = occurrences.map { occurrence in
            Placed(id: occurrence.id, title: occurrence.event.title, subtitle: data.whoLabel(occurrence.event), start: occurrence.start, end: max(occurrence.end, occurrence.start.addingTimeInterval(1800)), color: data.color(for: occurrence.event), ref: OccurrenceRef(eventID: occurrence.event.id, day: date))
        }
        items += apple.map { event in
            Placed(id: "apple-" + event.id, title: event.title, subtitle: event.calendarTitle, start: event.start, end: max(event.end, event.start.addingTimeInterval(1800)), color: event.color, ref: nil)
        }
        let placed = lay(items.sorted { $0.start < $1.start })
        let isToday = calendar.isDateInToday(date)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Tapping an empty time starts an event there, on the half hour.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let minutes = Int(location.y / hourHeight * 60) / 30 * 30
                        let start = calendar.date(byAdding: .minute, value: minutes, to: dayStart) ?? dayStart
                        onNew(NewEventRequest(day: date, start: start))
                    }
                    .accessibilityHidden(true)
                ForEach(placed) { item in
                    let top = CGFloat(item.start.timeIntervalSince(dayStart) / 3600) * hourHeight
                    let height = max(CGFloat(item.end.timeIntervalSince(item.start) / 3600) * hourHeight - 2, 22)
                    let width = (proxy.size.width - 4) / CGFloat(item.lanes)
                    block(item, height: height)
                        .frame(width: width - 2, height: height)
                        .offset(x: 2 + CGFloat(item.lane) * width, y: top + 1)
                }
                if isToday {
                    TimelineView(.everyMinute) { context in
                        let y = CGFloat(context.date.timeIntervalSince(dayStart) / 3600) * hourHeight
                        if y > 0 && y < CGFloat(lastHour - firstHour) * hourHeight {
                            Rectangle()
                                .fill(Brand.late)
                                .frame(height: 2)
                                .overlay(alignment: .leading) {
                                    Circle().fill(Brand.late).frame(width: 9, height: 9).offset(x: -4)
                                }
                                .offset(y: y)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(lastHour - firstHour) * hourHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
    }

    @ViewBuilder
    private func block(_ item: Placed, height: CGFloat) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(height < 40 ? 1 : 2)
            if height >= 40 {
                Text(item.start.formatted(date: .omitted, time: .shortened) + " · " + item.subtitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(item.color.mix(with: .primary, by: 0.3))
        .background(item.color.opacity(item.ref == nil ? 0.1 : 0.18), in: .rect(cornerRadius: 8))
        .overlay {
            if item.ref == nil {
                RoundedRectangle(cornerRadius: 8).strokeBorder(item.color.opacity(0.4), lineWidth: 1)
            }
        }
        if let ref = item.ref {
            Button { onOpen(ref) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.start.formatted(date: .omitted, time: .shortened))")
        } else {
            content
        }
    }

    /// Puts overlapping events side by side.
    private func lay(_ items: [Placed]) -> [Placed] {
        var result = items
        var laneEnds: [Date] = []
        var cluster: [Int] = []
        var clusterEnd = Date.distantPast
        func closeCluster() {
            let lanes = max(laneEnds.count, 1)
            for index in cluster { result[index].lanes = lanes }
            cluster = []
            laneEnds = []
        }
        for index in result.indices {
            if result[index].start >= clusterEnd { closeCluster() }
            if let free = laneEnds.firstIndex(where: { $0 <= result[index].start }) {
                result[index].lane = free
                laneEnds[free] = result[index].end
            } else {
                result[index].lane = laneEnds.count
                laneEnds.append(result[index].end)
            }
            cluster.append(index)
            clusterEnd = max(clusterEnd, result[index].end)
        }
        closeCluster()
        return result
    }
}
