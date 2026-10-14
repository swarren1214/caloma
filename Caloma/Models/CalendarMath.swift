import Foundation

// The calendar's arithmetic on plain records: when a repeating event happens, what's on a day,
// whose day it is, and how many sleeps until the next big thing. Tested in CalendarMathTests.

nonisolated struct EventRecord: Hashable, Sendable {
    var id: UUID = UUID()
    var title: String = ""
    var symbol: String = "calendar"
    var location: String = ""
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    /// Empty means everyone.
    var attendeeIDs: [UUID] = []
    var driverID: UUID?
    var repeatRule: EventRepeat = .never
    var weekdayMask: Int = 0
    var repeatEnd: Date?
    var bring: [String] = []
    var showInKidView: Bool = true
    var countsDown: Bool = false
    /// "yyyy-MM-dd" of skipped days.
    var skippedDays: Set<String> = []
    var isArchived: Bool = false

    var isEveryone: Bool { attendeeIDs.isEmpty }

    func includes(_ memberID: UUID) -> Bool { attendeeIDs.isEmpty || attendeeIDs.contains(memberID) }
}

/// One time an event happens.
nonisolated struct EventOccurrence: Identifiable, Hashable, Sendable {
    var event: EventRecord
    var start: Date
    var end: Date

    var id: String { "\(event.id.uuidString)@\(Int(start.timeIntervalSince1970))" }
}

nonisolated enum CalendarMath {
    /// "2026-10-13", for skipped days.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether an event starts on a day (for repeating events, whether it happens that day).
    static func happens(_ event: EventRecord, on day: Date, calendar: Calendar = .current) -> Bool {
        guard !event.isArchived else { return false }
        let date = calendar.startOfDay(for: day)
        let first = calendar.startOfDay(for: event.start)
        guard date >= first else { return false }
        if let end = event.repeatEnd, date > calendar.startOfDay(for: end) { return false }
        if event.skippedDays.contains(dayKey(date, calendar: calendar)) { return false }
        switch event.repeatRule {
        case .never:
            return date == first
        case .daily:
            return true
        case .weekly:
            let mask = event.weekdayMask == 0 ? ChoreMath.bit(forWeekday: calendar.component(.weekday, from: first)) : event.weekdayMask
            return mask & ChoreMath.bit(forWeekday: calendar.component(.weekday, from: date)) != 0
        case .monthly:
            return calendar.component(.day, from: date) == calendar.component(.day, from: first)
        case .yearly:
            return calendar.component(.day, from: date) == calendar.component(.day, from: first)
                && calendar.component(.month, from: date) == calendar.component(.month, from: first)
        }
    }

    /// The occurrence that starts on a day, with the event's time of day and length.
    static func occurrence(of event: EventRecord, startingOn day: Date, calendar: Calendar = .current) -> EventOccurrence {
        let date = calendar.startOfDay(for: day)
        let time = calendar.dateComponents([.hour, .minute], from: event.start)
        let start = event.isAllDay ? date : (calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: date) ?? date)
        let length = max(event.end.timeIntervalSince(event.start), 0)
        return EventOccurrence(event: event, start: start, end: start.addingTimeInterval(length))
    }

    /// Every occurrence that overlaps the days from `from` through `to` (whole days), in start
    /// order. Multi-day events show on each day they cover.
    static func occurrences(of events: [EventRecord], from: Date, through to: Date, calendar: Calendar = .current) -> [EventOccurrence] {
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        var result: [EventOccurrence] = []
        for event in events where !event.isArchived {
            // Start looking early enough to catch a long event that began before the range.
            let spanDays = Int(ceil(max(event.end.timeIntervalSince(event.start), 0) / 86_400))
            var day = calendar.date(byAdding: .day, value: -spanDays, to: first) ?? first
            while day <= last {
                if happens(event, on: day, calendar: calendar) {
                    let hit = occurrence(of: event, startingOn: day, calendar: calendar)
                    let ends = max(hit.end, hit.start.addingTimeInterval(1))
                    if hit.start < rangeEnd && ends > first {
                        result.append(hit)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result.sorted(by: order)
    }

    /// One day's occurrences: all-day ones first, then by time.
    static func occurrences(of events: [EventRecord], on day: Date, calendar: Calendar = .current) -> [EventOccurrence] {
        occurrences(of: events, from: day, through: day, calendar: calendar)
    }

    static func order(_ a: EventOccurrence, _ b: EventOccurrence) -> Bool {
        if a.event.isAllDay != b.event.isAllDay { return a.event.isAllDay }
        if a.start != b.start { return a.start < b.start }
        return a.event.title < b.event.title
    }

    /// Whole days from one day to another ("sleeps"): tonight's sleep counts as one.
    static func sleeps(from now: Date, until date: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// The next event someone is counting down to, within a year. For a kid, only theirs.
    static func nextCountdown(_ events: [EventRecord], for memberID: UUID? = nil, now: Date = .now, calendar: Calendar = .current) -> EventOccurrence? {
        let candidates = events.filter { event in
            event.countsDown && !event.isArchived && (memberID.map { event.includes($0) } ?? true)
        }
        guard !candidates.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...366 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            let hits = candidates.filter { happens($0, on: day, calendar: calendar) }
                .map { occurrence(of: $0, startingOn: day, calendar: calendar) }
                .filter { $0.event.isAllDay ? offset > 0 || $0.start >= today : $0.start > now }
                .sorted(by: order)
            if let first = hits.first { return first }
        }
        return nil
    }

    /// The seven days of the week a date is in, starting on the calendar's first weekday.
    static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// A month as whole weeks: the days before the 1st and after the last day fill out the
    /// first and last weeks.
    static func monthGrid(for date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) else { return [] }
        let first = week(containing: month.start, calendar: calendar).first ?? month.start
        let last = week(containing: lastDay, calendar: calendar).last ?? lastDay
        var days: [Date] = []
        var day = first
        while day <= last {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The weekday mask for the night before each day in `mask` (Monday → Sunday).
    static func nightBefore(mask: Int) -> Int {
        var result = 0
        for bit in 0..<7 where mask & (1 << bit) != 0 {
            result |= 1 << ((bit + 6) % 7)
        }
        return result
    }

    /// "4:30 – 5:45 PM", "All day".
    static func timeLabel(_ occurrence: EventOccurrence) -> String {
        if occurrence.event.isAllDay { return "All day" }
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        guard occurrence.end > occurrence.start else { return occurrence.start.formatted(style) }
        return (occurrence.start..<occurrence.end).formatted(.interval.hour().minute())
    }
}
