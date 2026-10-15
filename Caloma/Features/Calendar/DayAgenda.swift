import SwiftUI

/// One day on the calendar: all-day things on top, then events by time (family and Apple
/// Calendar together), then the day's chores. Tapping a family event opens it.
struct DayAgenda: View {
    @Environment(\.openURL) private var openURL
    var day: Date
    var data: CalendarData
    var occurrences: [EventOccurrence]
    var appleEvents: [AppleEvent]
    /// Chores and home care, when they're shown.
    var chores: [BoardItem]
    var homeTasks: [HomeTask]
    var onOpen: (OccurrenceRef) -> Void
    /// Starts a new event on this day (tapping "Nothing planned").
    var onNew: (() -> Void)? = nil

    var body: some View {
        let allDay = occurrences.filter(\.event.isAllDay)
        let timed = occurrences.filter { !$0.event.isAllDay }
        let appleAllDay = appleEvents.filter(\.isAllDay)
        let appleTimed = appleEvents.filter { !$0.isAllDay }
        let dinner = HearthLink.shared.dinner(on: day)
        let isEmpty = occurrences.isEmpty && appleEvents.isEmpty && chores.isEmpty && homeTasks.isEmpty && dinner == nil

        VStack(alignment: .leading, spacing: 8) {
            if !allDay.isEmpty || !appleAllDay.isEmpty || !homeTasks.isEmpty || dinner != nil {
                VStack(spacing: 6) {
                    if let dinner {
                        // Dinner from BigTable; tapping opens it there.
                        Button {
                            if let url = dinner.openURL { openURL(url) }
                        } label: {
                            AllDayStrip(title: dinner.title, symbol: dinner.symbol, detail: "Dinner", color: HearthLink.bigTableColor, dashed: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens in BigTable")
                    }
                    ForEach(allDay) { occurrence in
                        Button {
                            onOpen(OccurrenceRef(eventID: occurrence.event.id, day: day))
                        } label: {
                            AllDayStrip(title: occurrence.event.title, symbol: nil, detail: data.whoLabel(occurrence.event), color: data.color(for: occurrence.event), dashed: false)
                        }
                        .buttonStyle(.plain)
                        .eventDraggable(OccurrenceRef(eventID: occurrence.event.id, day: Calendar.current.startOfDay(for: occurrence.start)), title: occurrence.event.title, color: data.color(for: occurrence.event))
                    }
                    ForEach(appleAllDay) { event in
                        AllDayStrip(title: event.title, symbol: nil, detail: event.calendarTitle, color: event.color, dashed: false)
                    }
                    ForEach(homeTasks) { task in
                        NavigationLink {
                            HomeTaskDetailView(task: task)
                        } label: {
                            let late = Calendar.current.startOfDay(for: task.nextDue) < Calendar.current.startOfDay(for: .now)
                            AllDayStrip(title: task.name, symbol: task.symbol, detail: late ? HomeCareMath.dueLabel(task.nextDue) : "Home care", color: late ? Brand.late : Brand.waiting, dashed: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(merged(timed, appleTimed), id: \.id) { entry in
                switch entry {
                case .family(let occurrence):
                    Button {
                        onOpen(OccurrenceRef(eventID: occurrence.event.id, day: day))
                    } label: {
                        EventRow(occurrence: occurrence, data: data)
                    }
                    .buttonStyle(.plain)
                    .eventDraggable(OccurrenceRef(eventID: occurrence.event.id, day: Calendar.current.startOfDay(for: occurrence.start)), title: occurrence.event.title, color: data.color(for: occurrence.event))
                case .apple(let event):
                    AppleEventRow(event: event)
                }
            }

            if !chores.isEmpty {
                ChoresOfTheDay(items: chores, data: data)
            }

            if isEmpty {
                Button {
                    onNew?()
                } label: {
                    VStack(spacing: 6) {
                        Text("Nothing planned")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(onNew == nil ? "A free day." : "A free day. Tap to add something.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onNew == nil)
            }
        }
    }

    private enum Entry {
        case family(EventOccurrence)
        case apple(AppleEvent)

        var id: String {
            switch self {
            case .family(let occurrence): occurrence.id
            case .apple(let event): "apple-" + event.id
            }
        }

        var start: Date {
            switch self {
            case .family(let occurrence): occurrence.start
            case .apple(let event): event.start
            }
        }
    }

    private func merged(_ family: [EventOccurrence], _ apple: [AppleEvent]) -> [Entry] {
        (family.map(Entry.family) + apple.map(Entry.apple)).sorted { $0.start < $1.start }
    }
}

/// A full-width all-day line: "Picture day · Ella, Max". Home care is dashed.
struct AllDayStrip: View {
    var title: String
    /// Home care shows its task's icon; events don't have one.
    var symbol: String?
    var detail: String
    var color: Color
    var dashed: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(detail)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .opacity(0.85)
        }
        .foregroundStyle(dashed ? color : color.mix(with: .primary, by: 0.25))
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background {
            if dashed {
                RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.15))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A timed family event: the time on the left, then a card with the event's color, who's
/// going, and "Dad drives" / "Bring cleats".
struct EventRow: View {
    var occurrence: EventOccurrence
    var data: CalendarData

    var body: some View {
        let event = occurrence.event
        let color = data.color(for: event)
        let driver = data.member(event.driverID)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(occurrence.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.subheadline.weight(.semibold))
                Text(occurrence.start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))).filter { $0.isLetter })
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 50, alignment: .trailing)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !event.isEveryone {
                        FacePile(members: data.attendees(of: event))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if driver != nil || !event.bring.isEmpty {
                    HStack(spacing: 6) {
                        if let driver {
                            EventPill(text: "\(driver.name) drives", symbol: "car.fill", color: driver.color.color)
                        }
                        if !event.bring.isEmpty {
                            EventPill(text: "Bring " + event.bring.joined(separator: ", ").lowercased(), symbol: "bag.fill", color: .secondary)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the event")
    }

    private var subtitle: String {
        var parts: [String] = []
        if occurrence.end > occurrence.start {
            parts.append("Until \(occurrence.end.formatted(date: .omitted, time: .shortened))")
        }
        if !occurrence.event.location.isEmpty { parts.append(occurrence.event.location) }
        if parts.isEmpty { parts.append(data.whoLabel(occurrence.event)) }
        return parts.joined(separator: " · ")
    }
}

/// A timed event from Apple Calendar, read-only, with its calendar's name.
struct AppleEventRow: View {
    var event: AppleEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
                .padding(.top, 12)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.color)
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !event.location.isEmpty {
                            Text(event.location).lineLimit(1)
                        }
                        TagLabel(text: event.calendarTitle, color: event.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color(.separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The day's chores as a quiet list at the end of the day: each one with whose it is.
struct ChoresOfTheDay: View {
    var items: [BoardItem]
    var data: CalendarData
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.tab = .chores
            } label: {
                HStack {
                    Label("Chores", systemImage: "checklist")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(items.filter { $0.status.isDone }.count) of \(items.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(items.prefix(8)) { item in
                Divider().padding(.leading, 14)
                HStack(spacing: 10) {
                    Image(systemName: item.status.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.status.isDone ? (data.member(item.memberID)?.color.color ?? .secondary) : Color(.systemGray3))
                    Text(item.chore.title)
                        .font(.subheadline)
                        .strikethrough(item.status == .approved)
                        .foregroundStyle(item.status == .approved ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let member = data.member(item.memberID) {
                        Text(member.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(member.color.color)
                    } else {
                        Text("Up for grabs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
            }
            if items.count > 8 {
                Divider().padding(.leading, 14)
                Text("\(items.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}
