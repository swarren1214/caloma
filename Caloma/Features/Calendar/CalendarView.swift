import SwiftData
import SwiftUI

/// The family calendar. iPhone: a week strip and the day's agenda, or a month. iPad: the
/// family filters beside a week grid or a month.
struct CalendarView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accent) private var accent
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query(filter: #Predicate<HomeTask> { !$0.isArchived }) private var homeTasks: [HomeTask]
    @Bindable private var filter = CalendarFilter.shared
    /// Kiosk Mode's wall calendar: no new events or drags.
    @Environment(\.calendarReadOnly) private var readOnly

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var mode: Mode = .week
    /// iPhone: one person's calendar, or everyone's.
    @State private var person: UUID?
    @State private var open: OccurrenceRef?
    @State private var creating: NewEventRequest?
    /// "Write an Event" with the Apple Pencil.
    @State private var writing: NewEventRequest?
    /// A repeating event that was dragged, waiting on "Only this one" or "All of them".
    @State private var pendingMove: EventMove?

    private let apple = AppleCalendar.shared

    enum Mode: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month"
        var id: String { rawValue }
    }

    private var data: CalendarData {
        CalendarData(
            members: members.filter { !$0.isArchived },
            events: events.map(\.record),
            family: FamilySnapshot(members: members, chores: chores, completions: completions, points: []),
            homeTasks: homeTasks,
            accent: accent
        )
    }

    private func visible(_ event: EventRecord) -> Bool {
        if sizeClass == .regular {
            return filter.shows(event)
        }
        guard let person else { return true }
        return event.includes(person)
    }

    var body: some View {
        let data = data
        Group {
            if sizeClass == .regular {
                CalendarWideView(data: data, day: $day, mode: $mode, visible: visible, onNew: { if !readOnly { creating = $0 } }, onOpen: { open = $0 }, onMove: { if !readOnly { move($0) } }, onWrite: { writing = NewEventRequest(day: $0) }, canCreate: !readOnly)
            } else {
                compact(data)
            }
        }
        .navigationTitle(sizeClass == .regular ? "Calendar" : day.formatted(.dateTime.month(.wide)))
        // On iPad the calendar's own header ("October 2026") is the title, so the big
        // "Calendar" bar is hidden. The title stays for VoiceOver and the app switcher.
        .toolbarVisibility(sizeClass == .regular ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            // On iPad these are in the calendar's own header, as in the design.
            if sizeClass != .regular && !readOnly {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") {
                        withAnimation(.snappy) { day = Calendar.current.startOfDay(for: .now) }
                    }
                    Button {
                        creating = NewEventRequest(day: day)
                    } label: {
                        Label("New Event", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $creating) { request in
            EventEditor(event: nil, day: request.day, startAt: request.start, allDay: request.allDay)
        }
        .fullScreenCover(item: $writing) { request in
            WriteEventSheet(day: request.day, onTheWall: readOnly)
        }
        .sheet(item: $open) { ref in
            NavigationStack {
                EventDetailView(eventID: ref.eventID, day: ref.day)
            }
        }
        .confirmationDialog("Move this event?", isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible, presenting: pendingMove) { move in
            Button("Only This One") { perform(move, all: false) }
            Button("All of Them") { perform(move, all: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It repeats. Move just this day, or every time it happens?")
        }
        .sensoryFeedback(.success, trigger: moved)
        .onChange(of: router.pendingNewEvent, initial: true) { _, pending in
            guard pending, !readOnly else { return }
            router.pendingNewEvent = false
            creating = NewEventRequest(day: day)
        }
    }

    // MARK: iPhone

    @ViewBuilder
    private func compact(_ data: CalendarData) -> some View {
        CalomaScreen(title: day.formatted(.dateTime.month(.wide))) {
            Picker("View", selection: $mode.animation(.snappy)) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .week {
                WeekStrip(day: $day, data: data, visible: visible, onNew: readOnly ? nil : { date in creating = NewEventRequest(day: date) }, onDrop: readOnly ? nil : { ref, date in move(EventMove(ref: ref, toDay: date)) })
            } else {
                MonthGrid(day: $day, data: data, visible: visible, onNew: readOnly ? nil : { date in creating = NewEventRequest(day: date) }, onDrop: readOnly ? nil : { ref, date in move(EventMove(ref: ref, toDay: date)) })
            }

            if data.members.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Chip(title: "Everyone", color: accent, isOn: person == nil, showsDot: false) { person = nil }
                        ForEach(data.members) { member in
                            Chip(title: member.name, color: member.color.color, isOn: person == member.id) {
                                person = person == member.id ? nil : member.id
                            }
                        }
                        LayerChip(title: "Chores", isOn: filter.showChores) { filter.showChores.toggle() }
                        LayerChip(title: "Home Care", isOn: filter.showHomeCare) { filter.showHomeCare.toggle() }
                        if HearthLink.shared.mealPlan != nil {
                            LayerChip(title: "Meals", isOn: filter.showMeals) { filter.showMeals.toggle() }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)
            }

            if let countdown = CalendarMath.nextCountdown(data.events.filter(visible)) {
                Button {
                    day = Calendar.current.startOfDay(for: countdown.start)
                } label: {
                    CountdownCard(occurrence: countdown, color: data.color(for: countdown.event))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(dayTitle) {
                    Text(day.formatted(.dateTime.month(.abbreviated).day()))
                        .foregroundStyle(.secondary)
                }
                DayAgenda(
                    day: day,
                    data: data,
                    occurrences: data.occurrences(on: day, where: visible),
                    appleEvents: person == nil ? apple.events(from: day, through: day) : [],
                    chores: filter.showChores ? data.chores(on: day, for: person) : [],
                    homeTasks: filter.showHomeCare && person == nil ? data.homeTasksDue(on: day) : [],
                    onOpen: { open = $0 },
                    onNew: { if !readOnly { creating = NewEventRequest(day: day) } }
                )
            }
        }
    }

    @State private var moved = 0

    /// An event was dragged to a new day or time. Repeating events ask first.
    private func move(_ move: EventMove) {
        guard let event = Family.event(move.ref.eventID, in: context) else { return }
        let (oldStart, newStart) = starts(of: event, for: move)
        // Dropped back where it was.
        guard abs(newStart.timeIntervalSince(oldStart)) >= 60 else { return }
        if event.repeatRule == .never {
            perform(move, all: false)
        } else {
            pendingMove = move
        }
    }

    /// Where the dragged occurrence was, and where it's going.
    private func starts(of event: FamilyEvent, for move: EventMove) -> (Date, Date) {
        let oldStart = Family.occurrenceStart(of: event, on: move.ref.day)
        if let toStart = move.toStart { return (oldStart, toStart) }
        if event.isAllDay { return (oldStart, Calendar.current.startOfDay(for: move.toDay)) }
        return (oldStart, Family.sameTime(as: oldStart, on: move.toDay))
    }

    private func perform(_ move: EventMove, all: Bool) {
        pendingMove = nil
        guard let event = Family.event(move.ref.eventID, in: context) else { return }
        let (oldStart, newStart) = starts(of: event, for: move)
        guard abs(newStart.timeIntervalSince(oldStart)) >= 60 else { return }
        withAnimation(.snappy) {
            _ = Family.move(event, from: move.ref.day, to: newStart, allOccurrences: all, in: context)
        }
        moved += 1
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }
}

/// A chip that shows or hides chores or home care: filled when on, dashed when off.
struct LayerChip: View {
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .background {
                    if isOn {
                        Capsule().fill(Color(.secondarySystemGroupedBackground))
                    } else {
                        Capsule().strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Seven days with a dot for each person busy that day. Swipe or use the arrows for other
/// weeks.
struct WeekStrip: View {
    @Binding var day: Date
    var data: CalendarData
    var visible: (EventRecord) -> Bool
    /// Long-pressing a day offers New Event on it.
    var onNew: ((Date) -> Void)? = nil
    /// An event dropped on a day.
    var onDrop: ((OccurrenceRef, Date) -> Void)? = nil
    @Environment(\.accent) private var accent

    var body: some View {
        let calendar = Calendar.current
        let week = CalendarMath.week(containing: day)
        let occurrences = data.occurrences(from: week.first ?? day, through: week.last ?? day, where: visible)
        HStack(spacing: 0) {
            Button {
                move(by: -7)
            } label: {
                Image(systemName: "chevron.left").font(.footnote.weight(.bold)).frame(width: 28, height: 44)
            }
            .accessibilityLabel("Previous week")
            ForEach(week, id: \.self) { date in
                let selected = calendar.isDate(date, inSameDayAs: day)
                let today = calendar.isDateInToday(date)
                let colors = dotColors(on: date, occurrences: occurrences)
                Button {
                    withAnimation(.snappy) { day = date }
                } label: {
                    VStack(spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.day()))
                            .font(.body.weight(selected || today ? .bold : .medium))
                            .monospacedDigit()
                            .frame(width: 36, height: 36)
                            .foregroundStyle(selected ? (today ? Color.white : Color(.systemBackground)) : (today ? accent : Color.primary))
                            .background {
                                if selected { Circle().fill(today ? accent : Color.primary) }
                            }
                        HStack(spacing: 3) {
                            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                                Circle().fill(color).frame(width: 6, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month().day()) + (today ? ", today" : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    if let onNew {
                        Button("New Event", systemImage: "plus") { onNew(date) }
                    }
                }
                .eventDropTarget(on: date, perform: onDrop)
            }
            Button {
                move(by: 7)
            } label: {
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).frame(width: 28, height: 44)
            }
            .accessibilityLabel("Next week")
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40 { move(by: 7) }
            if value.translation.width > 40 { move(by: -7) }
        })
    }

    private func move(by days: Int) {
        withAnimation(.snappy) {
            day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        }
    }

    private func dotColors(on date: Date, occurrences: [EventOccurrence]) -> [Color] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var seen = Set<String>()
        var colors: [Color] = []
        for occurrence in occurrences where occurrence.start < dayEnd && max(occurrence.end, occurrence.start.addingTimeInterval(1)) > dayStart {
            let key = occurrence.event.isEveryone ? "everyone" : (occurrence.event.attendeeIDs.first?.uuidString ?? "")
            if seen.insert(key).inserted { colors.append(data.color(for: occurrence.event)) }
        }
        return colors
    }
}

/// A month as a grid of days, each with dots for who's busy.
struct MonthGrid: View {
    @Binding var day: Date
    var data: CalendarData
    var visible: (EventRecord) -> Bool
    var cellHeight: CGFloat = 46
    /// Long-pressing a day offers New Event on it.
    var onNew: ((Date) -> Void)? = nil
    /// An event dropped on a day.
    var onDrop: ((OccurrenceRef, Date) -> Void)? = nil
    @Environment(\.accent) private var accent

    var body: some View {
        let calendar = Calendar.current
        let grid = CalendarMath.monthGrid(for: day)
        let occurrences = data.occurrences(from: grid.first ?? day, through: grid.last ?? day, where: visible)
        let month = calendar.component(.month, from: day)
        VStack(spacing: 6) {
            HStack {
                Text(day.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Previous month")
                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Next month")
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(CalendarMath.week(containing: day), id: \.self) { date in
                    Text(date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(grid, id: \.self) { date in
                    let inMonth = calendar.component(.month, from: date) == month
                    let selected = calendar.isDate(date, inSameDayAs: day)
                    let today = calendar.isDateInToday(date)
                    Button {
                        withAnimation(.snappy) { day = date }
                    } label: {
                        VStack(spacing: 3) {
                            Text(date.formatted(.dateTime.day()))
                                .font(.callout.weight(selected || today ? .bold : .regular))
                                .monospacedDigit()
                                .frame(width: 30, height: 30)
                                .foregroundStyle(selected ? (today ? Color.white : Color(.systemBackground)) : (today ? accent : (inMonth ? Color.primary : Color(.tertiaryLabel))))
                                .background {
                                    if selected { Circle().fill(today ? accent : Color.primary) }
                                }
                            HStack(spacing: 2) {
                                ForEach(Array(dots(on: date, occurrences: occurrences).prefix(4).enumerated()), id: \.offset) { _, color in
                                    Circle().fill(color).frame(width: 5, height: 5)
                                }
                            }
                            .frame(height: 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: cellHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month().day()))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        if let onNew {
                            Button("New Event", systemImage: "plus") { onNew(date) }
                        }
                    }
                    .eventDropTarget(on: date, cornerRadius: 10, perform: onDrop)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40 { move(by: 1) }
            if value.translation.width > 40 { move(by: -1) }
        })
    }

    private func move(by months: Int) {
        withAnimation(.snappy) {
            day = Calendar.current.date(byAdding: .month, value: months, to: day) ?? day
        }
    }

    private func dots(on date: Date, occurrences: [EventOccurrence]) -> [Color] {
        let calendar = Calendar.current
        var seen = Set<String>()
        var colors: [Color] = []
        for occurrence in occurrences {
            let start = calendar.startOfDay(for: occurrence.start)
            let last = calendar.startOfDay(for: max(occurrence.start, occurrence.end.addingTimeInterval(-1)))
            let date = calendar.startOfDay(for: date)
            guard date >= start && date <= last else { continue }
            let people = occurrence.event.isEveryone ? ["everyone"] : occurrence.event.attendeeIDs.map(\.uuidString)
            for key in people where seen.insert(key).inserted {
                if key == "everyone" {
                    colors.append(accent)
                } else if let member = data.members.first(where: { $0.id.uuidString == key }) {
                    colors.append(member.color.color)
                }
            }
        }
        return colors
    }
}

#Preview {
    NavigationStack { CalendarView() }
        .previewEnvironment()
}
