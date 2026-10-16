import Foundation
import SwiftData

// The family calendar. Same CloudKit rules as the rest: defaults everywhere, nothing unique,
// links by UUID.

/// Something on the family calendar: soccer practice, a dentist visit, a birthday party.
@Model
final class FamilyEvent {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var title: String = ""
    var symbol: String = "calendar"
    var location: String = ""
    var notes: String = ""
    /// For a repeating event, the first time it happens.
    var start: Date = Date.now
    var end: Date = Date.now
    var isAllDay: Bool = false
    /// Who's going, as comma-separated member UUIDs. Empty means everyone.
    var attendeeIDsRaw: String = ""
    /// The parent driving, if anyone.
    var driverID: UUID?
    var repeatRaw: String = EventRepeat.never.rawValue
    /// For weekly events: bit 0 is Sunday … bit 6 is Saturday. 0 means the start's weekday.
    var weekdayMask: Int = 0
    /// The last day it repeats, if it stops.
    var repeatEnd: Date?
    /// Minutes before to remind, or -1 for no alert.
    var alertMinutes: Int = -1
    /// What to bring, one item per line. Kids tick these off in Kid View.
    var bringRaw: String = ""
    var showInKidView: Bool = true
    /// Kid View counts the sleeps until it.
    var countsDown: Bool = false
    /// The chore made for the night before ("Get ready for soccer practice"), if any.
    var getReadyChoreID: UUID?
    /// Days a repeating event is skipped, as comma-separated "yyyy-MM-dd".
    var skippedDaysRaw: String = ""
    var isArchived: Bool = false
    var createdAt: Date = Date.now
    /// Written with the Apple Pencil: the handwritten title, as PencilKit data. The typed
    /// `title` is what Caloma read from it, for search, widgets and notifications.
    @Attribute(.externalStorage) var handwriting: Data?
    /// Whose ink color it was written in.
    var inkMemberID: UUID?

    init(title: String, start: Date, end: Date, isAllDay: Bool = false, attendeeIDs: [UUID] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendeeIDsRaw = Chore.encode(attendeeIDs)
    }

    var attendeeIDs: [UUID] {
        get { Chore.decode(attendeeIDsRaw) }
        set { attendeeIDsRaw = Chore.encode(newValue) }
    }

    var repeatRule: EventRepeat {
        get { EventRepeat(rawValue: repeatRaw) ?? .never }
        set { repeatRaw = newValue.rawValue }
    }

    var bring: [String] {
        get { bringRaw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { bringRaw = newValue.joined(separator: "\n") }
    }

    var skippedDays: [String] {
        get { skippedDaysRaw.split(separator: ",").map(String.init) }
        set { skippedDaysRaw = newValue.joined(separator: ",") }
    }

    var record: EventRecord {
        EventRecord(id: id, title: title, symbol: symbol, location: location, start: start, end: end, isAllDay: isAllDay, attendeeIDs: attendeeIDs, driverID: driverID, repeatRule: repeatRule, weekdayMask: weekdayMask, repeatEnd: repeatEnd, bring: bring, showInKidView: showInKidView, countsDown: countsDown, skippedDays: Set(skippedDays), isArchived: isArchived)
    }
}

nonisolated enum EventRepeat: String, CaseIterable, Identifiable, Codable, Sendable {
    case never, daily, weekly, monthly, yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}

/// Which "bring" items a kid has packed for one day of an event.
@Model
final class EventPacking {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var eventID: UUID?
    var memberID: UUID?
    /// The day of the occurrence (start of day).
    var day: Date = Date.now
    /// The packed items, one per line.
    var packedRaw: String = ""

    init(eventID: UUID, memberID: UUID, day: Date) {
        self.eventID = eventID
        self.memberID = memberID
        self.day = day
    }

    var packed: Set<String> {
        get { Set(packedRaw.split(separator: "\n").map(String.init)) }
        set { packedRaw = newValue.sorted().joined(separator: "\n") }
    }
}
