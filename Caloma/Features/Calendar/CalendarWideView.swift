import SwiftUI
import UniformTypeIdentifiers

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
    var onMove: (EventMove) -> Void
    /// "Write an Event" with the Apple Pencil, for this day. Also on the Kiosk Mode wall.
    var onWrite: ((Date) -> Void)?
    /// Typed New Event; off on the Kiosk Mode wall.
    var canCreate = true

    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the weeks sit while a turn or spring-back animates.
    @State private var dragOffset: CGFloat = 0
    /// The finger, while it's down. Resets by itself if the drag is cancelled (say, by
    /// picking up an event to move it), so the weeks never stay stuck partway.
    @GestureState private var liveDrag = PagerDrag()
    @State private var pageWidth: CGFloat = 0
    /// A week turn is animating; drags and taps wait for it.
    @State private var paging = false
    private let pageGap: CGFloat = 16
    private let apple = AppleCalendar.shared
    private let filter = CalendarFilter.shared
    private var showChores: Bool { filter.showChores }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if mode == .week {
                    weekPager
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        MonthGrid(day: $day, data: data, visible: visible, cellHeight: 64, onNew: { date in onNew(NewEventRequest(day: date)) }, onDrop: { ref, date in onMove(EventMove(ref: ref, toDay: date)) })
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
                                    homeTasks: filter.showHomeCare ? data.homeTasksDue(on: day) : [],
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
                        go(to: Calendar.current.startOfDay(for: .now))
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
                if let onWrite {
                    Button {
                        onWrite(writeDay)
                    } label: {
                        Label("Write", systemImage: "applepencil.and.scribble")
                            .font(.subheadline.weight(.semibold))
                            .padding(.leading, 12)
                            .padding(.trailing, 16)
                            .frame(height: 40)
                            .foregroundStyle(canCreate ? accent : .white)
                            .glassEffect(canCreate ? Glass.regular.interactive() : Glass.regular.tint(accent).interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Write an Event")
                }
                if canCreate {
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
    }

    /// Today when today is in view, otherwise the first day showing.
    private var writeDay: Date {
        let calendar = Calendar.current
        if mode == .week {
            let week = CalendarMath.week(containing: day)
            if week.contains(where: { calendar.isDateInToday($0) }) { return calendar.startOfDay(for: .now) }
            return week.first ?? day
        }
        return day
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
            Toggle("Chores", isOn: Binding(get: { filter.showChores }, set: { filter.showChores = $0 }))
            Toggle("Home Care", isOn: Binding(get: { filter.showHomeCare }, set: { filter.showHomeCare = $0 }))
            if HearthLink.shared.mealPlan != nil {
                Toggle("Meals", isOn: Binding(get: { filter.showMeals }, set: { filter.showMeals = $0 }))
            }
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
        let component: Calendar.Component = mode == .week ? .weekOfYear : .month
        go(to: Calendar.current.date(byAdding: component, value: step, to: day) ?? day)
    }

    /// Changes the day. In the week grid, a week next door turns like a page; further away
    /// cross-fades.
    private func go(to newDay: Date) {
        guard !paging else { return }
        guard mode == .week else {
            withAnimation(.snappy) { day = newDay }
            return
        }
        let calendar = Calendar.current
        let from = CalendarMath.week(containing: day).first ?? day
        let to = CalendarMath.week(containing: newDay).first ?? newDay
        let weeks = calendar.dateComponents([.weekOfYear], from: from, to: to).weekOfYear ?? 0
        if weeks == 0 {
            withAnimation(.snappy) { day = newDay }
        } else if abs(weeks) == 1 && !reduceMotion && pageWidth > 0 {
            turn(weeks, to: newDay)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { day = newDay }
        }
    }

    // MARK: Week pager

    /// Last week, this week and next week side by side, this week showing. A sideways drag
    /// moves them with the finger; letting go far enough (or with a flick) turns the page,
    /// otherwise it springs back. Up and down still scrolls the hours.
    private var weekPager: some View {
        let calendar = Calendar.current
        let pages = [-1, 0, 1].map { step in
            let date = calendar.date(byAdding: .weekOfYear, value: step, to: day) ?? day
            let days = CalendarMath.week(containing: date)
            return WeekPage(key: CalendarMath.dayKey(days.first ?? date), days: days)
        }
        return GeometryReader { proxy in
            HStack(spacing: pageGap) {
                ForEach(pages) { page in
                    WeekGrid(data: data, week: page.days, visible: visible, showChores: showChores, showHomeCare: filter.showHomeCare, showMeals: filter.showMeals, onNew: onNew, onOpen: onOpen, onMove: onMove)
                        .frame(width: proxy.size.width)
                        // The neighbors are only glimpsed while dragging.
                        .accessibilityHidden(page.key != pages[1].key)
                }
            }
            .offset(x: -(proxy.size.width + pageGap) + dragOffset + liveDrag.dx)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .clipShape(.rect(cornerRadius: 22))
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($liveDrag) { value, state, _ in
                    guard !paging else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Decided once per drag: sideways turns weeks, up and down scrolls hours.
                    if state.axis == nil, abs(dx) > 10 || abs(dy) > 10 {
                        state.axis = abs(dx) > abs(dy) * 1.2 ? .horizontal : .vertical
                    }
                    if state.axis == .horizontal {
                        state.dx = dx
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    guard !paging, abs(dx) > abs(value.translation.height) * 1.2 else { return }
                    // Carry on from where the finger left the weeks.
                    var hold = Transaction()
                    hold.disablesAnimations = true
                    withTransaction(hold) { dragOffset = dx }
                    let flick = value.predictedEndTranslation.width
                    if abs(dx) > pageWidth * 0.25 || (abs(flick) > pageWidth * 0.5 && flick.sign == dx.sign) {
                        let step = dx < 0 ? 1 : -1
                        turn(step, to: calendar.date(byAdding: .weekOfYear, value: step, to: day) ?? day)
                    } else {
                        withAnimation(.smooth(duration: 0.3)) { dragOffset = 0 }
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: pages[1].key)
    }

    /// Slides to the week next door, from wherever a drag left it, then makes it this week
    /// without moving anything on screen.
    private func turn(_ step: Int, to newDay: Date) {
        guard pageWidth > 0 else {
            day = newDay
            return
        }
        paging = true
        let target = (pageWidth + pageGap) * (step > 0 ? -1 : 1)
        withAnimation(.smooth(duration: 0.35)) {
            dragOffset = target
        } completion: {
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) {
                day = newDay
                dragOffset = 0
            }
            paging = false
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
    var showHomeCare: Bool
    /// BigTable's meals, at breakfast, lunch and dinner time with their photos.
    var showMeals: Bool = false
    var onNew: (NewEventRequest) -> Void
    var onOpen: (OccurrenceRef) -> Void
    var onMove: (EventMove) -> Void

    @Environment(\.accent) private var accent
    @Environment(\.openURL) private var openURL
    private let apple = AppleCalendar.shared
    private let hourHeight: CGFloat = 52
    /// Where a dragged event would land, shown as a line with its new time.
    @State private var dropHover: DropHover?
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
                            .eventDraggable(OccurrenceRef(eventID: occurrence.event.id, day: calendar.startOfDay(for: occurrence.start)), title: occurrence.event.title, color: data.color(for: occurrence.event))
                        }
                        ForEach(appleEvents.filter { $0.isAllDay && calendar.isDate($0.start, inSameDayAs: date) }) { event in
                            chip(event.title, color: event.color, dashed: false)
                        }
                        if showHomeCare {
                            ForEach(data.homeTasksDue(on: date)) { task in
                                chip(task.name, color: calendar.startOfDay(for: task.nextDue) < calendar.startOfDay(for: .now) ? Brand.late : Brand.waiting, dashed: true)
                            }
                        }
                        if showChores {
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
                    .eventDropTarget(on: date, cornerRadius: 6) { ref, day in onMove(EventMove(ref: ref, toDay: day)) }
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
                    ForEach(Array(week.enumerated()), id: \.element) { index, date in
                        let timedHere = timed(on: date, occurrences: occurrences)
                        dayColumn(date, index: index, occurrences: timedHere, apple: appleEvents.filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: date) })
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
        /// A meal from BigTable, drawn with its photo.
        var meal: HearthMealPlan.Meal? = nil
        var lane = 0
        var lanes = 1
    }

    private func dayColumn(_ date: Date, index: Int, occurrences: [EventOccurrence], apple: [AppleEvent]) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: date) ?? date
        var items: [Placed] = occurrences.map { occurrence in
            Placed(id: occurrence.id, title: occurrence.event.title, subtitle: data.whoLabel(occurrence.event), start: occurrence.start, end: max(occurrence.end, occurrence.start.addingTimeInterval(1800)), color: data.color(for: occurrence.event), ref: OccurrenceRef(eventID: occurrence.event.id, day: date))
        }
        items += apple.map { event in
            Placed(id: "apple-" + event.id, title: event.title, subtitle: event.calendarTitle, start: event.start, end: max(event.end, event.start.addingTimeInterval(1800)), color: event.color, ref: nil)
        }
        if showMeals {
            items += HearthLink.shared.meals(on: date).map { meal in
                let start = meal.start(on: date)
                return Placed(id: "meal-\(meal.slot)", title: meal.isDineOut ? (meal.placeName ?? meal.title) : meal.title, subtitle: meal.slotLabel, start: start, end: start.addingTimeInterval(Double(meal.calendarMinutes) * 60), color: HearthLink.bigTableColor, ref: nil, meal: meal)
            }
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
                // While an event is dragged over this day: where it would start.
                if let dropHover, dropHover.day == date {
                    DropLine(minutes: dropHover.minutes, hourHeight: hourHeight, color: accent, dayStart: dayStart)
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
        // Touch and hold an event, then drop it on any day and time; it starts where you let go.
        .onDrop(of: [.text], delegate: EventTimeDrop(day: date, dayStart: dayStart, hourHeight: hourHeight, hover: $dropHover) { ref, start in
            onMove(EventMove(ref: ref, toDay: date, toStart: start))
        })
    }

    @ViewBuilder
    private func block(_ item: Placed, height: CGFloat) -> some View {
        if let meal = item.meal {
            mealBlock(meal, title: item.title, height: height)
        } else {
            eventBlock(item, height: height)
        }
    }

    /// A meal from BigTable: its photo (or restaurant logo) beside the meal and its name.
    /// Tapping opens it in BigTable.
    private func mealBlock(_ meal: HearthMealPlan.Meal, title: String, height: CGFloat) -> some View {
        let thumb = min(height - 8, 36)
        return Button {
            if let url = meal.openURL { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                MealArtwork(meal: meal, cornerRadius: 6)
                    .frame(width: thumb, height: thumb)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(height < 40 ? 1 : 2)
                    if height >= 40 {
                        Text(meal.slotLabel)
                            .font(.caption2)
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(HearthLink.bigTableColor.mix(with: .primary, by: 0.3))
            .background(HearthLink.bigTableColor.opacity(0.14), in: .rect(cornerRadius: 8))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(HearthLink.bigTableColor)
                    .frame(width: 3)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(meal.slotLabel): \(title)")
        .accessibilityHint("Opens in BigTable")
    }

    @ViewBuilder
    private func eventBlock(_ item: Placed, height: CGFloat) -> some View {
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
            // Tap to open; touch and hold to pick it up and drag it to another day or time.
            Button { onOpen(ref) } label: { content }
                .buttonStyle(.plain)
                .eventDraggable(ref, title: item.title, color: item.color)
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

/// An event dragged over a day: the quarter hour it would start at.
struct DropHover: Equatable {
    var day: Date
    var minutes: Int
}

/// Dropping an event on a day column of the iPad week. The time comes from where the finger
/// is, snapped to the quarter hour, and shows as a line while it hovers.
private struct EventTimeDrop: DropDelegate {
    var day: Date
    var dayStart: Date
    var hourHeight: CGFloat
    @Binding var hover: DropHover?
    var perform: (OccurrenceRef, Date) -> Void

    private func minutes(_ info: DropInfo) -> Int {
        let raw = Double(info.location.y / hourHeight * 60)
        return min(max(Int((raw / 15).rounded()) * 15, 0), 23 * 60 + 45)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        hover = DropHover(day: day, minutes: minutes(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let now = DropHover(day: day, minutes: minutes(info))
        if hover != now { hover = now }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.day == day { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let start = dayStart.addingTimeInterval(Double(minutes(info)) * 60)
        hover = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let ref = OccurrenceRef(payload: text as String) else { return }
            Task { @MainActor in perform(ref, start) }
        }
        return true
    }
}

/// The line and time where a dragged event would start.
private struct DropLine: View {
    var minutes: Int
    var hourHeight: CGFloat
    var color: Color
    var dayStart: Date

    var body: some View {
        let y = CGFloat(minutes) / 60 * hourHeight
        Rectangle()
            .fill(color)
            .frame(height: 2)
            .overlay(alignment: .leading) {
                Text(dayStart.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(color, in: Capsule())
                    .fixedSize()
                    .offset(y: -12)
            }
            .offset(y: y)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.12), value: minutes)
    }
}

/// One week in the pager, keyed by its first day so a turn keeps each grid (and its scroll).
private struct WeekPage: Identifiable {
    let key: String
    let days: [Date]
    var id: String { key }
}

/// A sideways drag on the week pager: which way it's going, and how far.
private struct PagerDrag {
    var axis: Axis?
    var dx: CGFloat = 0
}
