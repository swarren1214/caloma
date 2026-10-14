import SwiftData
import SwiftUI

/// What the calendar screens draw from: the family, its events, chores and home care, plus
/// Apple Calendar when it's turned on.
struct CalendarData {
    var members: [Member]
    var events: [EventRecord]
    var family: FamilySnapshot
    var homeTasks: [HomeTask]
    var accent: Color

    func member(_ id: UUID?) -> Member? {
        guard let id else { return nil }
        return members.first { $0.id == id }
    }

    /// The people going, in family order. Empty for everyone.
    func attendees(of event: EventRecord) -> [Member] {
        members.filter { event.attendeeIDs.contains($0.id) }
    }

    /// One person: their color. Everyone: the accent. A few people: the first one's color.
    func color(for event: EventRecord) -> Color {
        if event.isEveryone { return accent }
        return attendees(of: event).first?.color.color ?? accent
    }

    func occurrences(from: Date, through: Date, where visible: (EventRecord) -> Bool) -> [EventOccurrence] {
        CalendarMath.occurrences(of: events.filter(visible), from: from, through: through)
    }

    func occurrences(on day: Date, where visible: (EventRecord) -> Bool) -> [EventOccurrence] {
        occurrences(from: day, through: day, where: visible)
    }

    /// Chores on a day, everyone's or one person's.
    func chores(on day: Date, for person: UUID? = nil) -> [BoardItem] {
        family.items(on: day).filter { item in
            guard let person else { return true }
            return item.memberID == person || (item.memberID == nil && item.chore.assigneeIDs.contains(person))
        }
    }

    /// Home care due on a day. Today also shows everything overdue.
    func homeTasksDue(on day: Date, calendar: Calendar = .current) -> [HomeTask] {
        let start = calendar.startOfDay(for: day)
        let isToday = calendar.isDateInToday(day)
        return homeTasks.filter { task in
            let due = calendar.startOfDay(for: task.nextDue)
            return due == start || (isToday && due < start)
        }
    }

    /// "Ella, Max", "Everyone".
    func whoLabel(_ event: EventRecord) -> String {
        event.isEveryone ? "Everyone" : attendees(of: event).map(\.name).formatted(.list(type: .and))
    }
}

/// Who's shown on the calendar, shared by the calendar and the app's sidebar on iPad (where
/// the family sits under the tabs, each person's photo in a ring of their color).
@Observable
final class CalendarFilter {
    static let shared = CalendarFilter()

    /// People hidden, by UUID string; "everyone" hides family-wide events.
    var hidden: Set<String> = []

    var showChores: Bool = UserDefaults.standard.object(forKey: "calendar.showChores") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showChores, forKey: "calendar.showChores") }
    }

    func isShown(_ key: String) -> Bool { !hidden.contains(key) }

    func toggle(_ key: String) {
        if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
    }

    func shows(_ event: EventRecord) -> Bool {
        if event.isEveryone { return !hidden.contains("everyone") }
        return event.attendeeIDs.contains { !hidden.contains($0.uuidString) }
    }
}

/// Which occurrence is open: an event and the day it's on.
struct OccurrenceRef: Identifiable, Hashable {
    var eventID: UUID
    var day: Date
    var id: String { "\(eventID.uuidString)@\(Int(day.timeIntervalSince1970))" }
}

/// A profile photo inside a ring of the person's color. Dimmed and gray when they're hidden.
struct PersonRing: View {
    var member: Member?
    var isOn: Bool = true
    var size: CGFloat = 36
    @Environment(\.accent) private var accent

    var body: some View {
        let ring = member?.color.color ?? accent
        ZStack {
            Circle()
                .strokeBorder(isOn ? ring : Color(.separator), lineWidth: 2.5)
            Group {
                if let member {
                    MemberAvatar(member, size: size - 8)
                } else {
                    // Everyone: a wheel of the family's colors.
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: size - 8, height: size - 8)
                        .background(accent, in: Circle())
                }
            }
            .grayscale(isOn ? 0 : 1)
        }
        .frame(width: size, height: size)
        .opacity(isOn ? 1 : 0.45)
        .animation(.smooth(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

/// Small overlapping faces of who's going.
struct FacePile: View {
    var members: [Member]
    var size: CGFloat = 24
    var ring: Color = Color(.secondarySystemGroupedBackground)

    var body: some View {
        HStack(spacing: -size * 0.33) {
            ForEach(members.prefix(4)) { member in
                MemberAvatar(member, size: size)
                    .overlay(Circle().strokeBorder(ring, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A rounded pill on an event: "Dad drives", "Bring cleats".
struct EventPill: View {
    var text: String
    var symbol: String
    var color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The countdown card: "11 days · Ella's birthday party".
struct CountdownCard: View {
    var occurrence: EventOccurrence
    var color: Color

    var body: some View {
        let sleeps = CalendarMath.sleeps(from: .now, until: occurrence.start)
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(sleeps.formatted())
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(sleeps == 1 ? "DAY" : "DAYS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(LinearGradient(colors: [color, color.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("COUNTING DOWN")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
                Text(occurrence.event.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(occurrence.start.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sleeps) days until \(occurrence.event.title)")
    }
}

extension EventRepeat {
    /// "Every Tuesday and Thursday", "Every day", "Every month on the 9th".
    func summary(start: Date, weekdayMask: Int, calendar: Calendar = .current) -> String {
        switch self {
        case .never:
            return "Doesn't repeat"
        case .daily:
            return "Every day"
        case .weekly:
            let mask = weekdayMask == 0 ? ChoreMath.bit(forWeekday: calendar.component(.weekday, from: start)) : weekdayMask
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            let names = order.filter { mask & ChoreMath.bit(forWeekday: $0) != 0 }.map { calendar.weekdaySymbols[$0 - 1] }
            return "Every " + names.formatted(.list(type: .and))
        case .monthly:
            return "Every month on the \(calendar.component(.day, from: start).formatted(.number))" + ordinalSuffix(calendar.component(.day, from: start))
        case .yearly:
            return "Every year on \(start.formatted(.dateTime.month(.wide).day()))"
        }
    }

    private func ordinalSuffix(_ day: Int) -> String {
        switch day % 100 {
        case 11, 12, 13: return "th"
        default:
            switch day % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }
}

/// The alert choices in the event editor, in minutes before (-1 is none).
struct EventAlertChoice: Identifiable {
    var minutes: Int
    var label: String
    var id: Int { minutes }

    static let all: [EventAlertChoice] = [
        EventAlertChoice(minutes: -1, label: "None"), EventAlertChoice(minutes: 0, label: "At time of event"),
        EventAlertChoice(minutes: 15, label: "15 minutes before"), EventAlertChoice(minutes: 30, label: "30 minutes before"),
        EventAlertChoice(minutes: 60, label: "1 hour before"), EventAlertChoice(minutes: 120, label: "2 hours before"),
        EventAlertChoice(minutes: 1440, label: "1 day before"),
    ]

    static func label(_ minutes: Int) -> String {
        all.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes before"
    }
}
