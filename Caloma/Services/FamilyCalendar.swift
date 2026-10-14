import Foundation
import SwiftData

/// Changes to the family calendar.
extension Family {
    /// Called after an event is inserted or edited: keeps its get-ready chore in step, and
    /// refreshes alerts and Apple Calendar.
    static func didSave(_ event: FamilyEvent, getReady: Bool, getReadyPoints: Int = 5, in context: ModelContext) {
        syncGetReadyChore(for: event, on: getReady, points: getReadyPoints, in: context)
        Persistence.save(context)
        EventAlerts.reschedule(in: context)
        AppleCalendar.shared.pushFamilyEvents(in: context)
    }

    /// Deletes an event and its get-ready chore.
    static func delete(_ event: FamilyEvent, in context: ModelContext) {
        if let chore = Self.chore(event.getReadyChoreID, in: context) {
            chore.isArchived = true
        }
        let id: UUID? = event.id
        let packings = (try? context.fetch(FetchDescriptor<EventPacking>(predicate: #Predicate { $0.eventID == id }))) ?? []
        for packing in packings { context.delete(packing) }
        context.delete(event)
        Persistence.save(context)
        EventAlerts.reschedule(in: context)
        AppleCalendar.shared.pushFamilyEvents(in: context)
    }

    /// Skips one day of a repeating event ("No practice this Thursday").
    static func skip(_ event: FamilyEvent, on day: Date, in context: ModelContext) {
        let key = CalendarMath.dayKey(day)
        if !event.skippedDays.contains(key) {
            event.skippedDays.append(key)
        }
        Persistence.save(context)
        EventAlerts.reschedule(in: context)
        AppleCalendar.shared.pushFamilyEvents(in: context)
    }

    /// When the occurrence on `day` starts.
    static func occurrenceStart(of event: FamilyEvent, on day: Date) -> Date {
        CalendarMath.occurrence(of: event.record, startingOn: day).start
    }

    /// The same time of day on another day, for dropping an event on a day (not a time).
    static func sameTime(as start: Date, on day: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }

    /// Drag to reschedule: moves the occurrence on `day` so it starts at `newStart`, keeping
    /// its length. For a repeating event, `allOccurrences` moves the whole series by the same
    /// amount; otherwise just that day moves (it's skipped, and a one-time copy is made).
    @discardableResult
    static func move(_ event: FamilyEvent, from day: Date, to newStart: Date, allOccurrences: Bool, in context: ModelContext) -> FamilyEvent {
        let calendar = Calendar.current
        let oldStart = occurrenceStart(of: event, on: day)
        let delta = newStart.timeIntervalSince(oldStart)
        guard abs(delta) >= 60 else { return event }
        let length = event.end.timeIntervalSince(event.start)
        let getReady = event.getReadyChoreID != nil

        if event.repeatRule == .never || allOccurrences {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: oldStart), to: calendar.startOfDay(for: newStart)).day ?? 0
            // Whole days by the calendar (so a clock change doesn't shift the time), plus the
            // change in time of day.
            let timeShift = newStart.timeIntervalSince(calendar.startOfDay(for: newStart)) - oldStart.timeIntervalSince(calendar.startOfDay(for: oldStart))
            event.start = (calendar.date(byAdding: .day, value: days, to: event.start) ?? event.start).addingTimeInterval(timeShift)
            event.end = event.start.addingTimeInterval(length)
            if let repeatEnd = event.repeatEnd {
                event.repeatEnd = calendar.date(byAdding: .day, value: days, to: repeatEnd)
            }
            // Weekly on Tue and Thu, dragged a day later, becomes Wed and Fri.
            if event.weekdayMask != 0, days % 7 != 0 {
                event.weekdayMask = rotate(event.weekdayMask, by: days)
            }
            // Skipped days move with the series.
            if !event.skippedDays.isEmpty, days != 0 {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                event.skippedDays = event.skippedDays.compactMap { key in
                    formatter.date(from: key).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map { CalendarMath.dayKey($0) }
                }
            }
            didSave(event, getReady: getReady, in: context)
            return event
        }

        // Just this one: skip the day in the series, and add a one-time copy at the new time.
        let copy = FamilyEvent(title: event.title, start: newStart, end: newStart.addingTimeInterval(length), isAllDay: event.isAllDay, attendeeIDs: event.attendeeIDs)
        copy.symbol = event.symbol
        copy.location = event.location
        copy.notes = event.notes
        copy.driverID = event.driverID
        copy.alertMinutes = event.alertMinutes
        copy.bringRaw = event.bringRaw
        copy.showInKidView = event.showInKidView
        copy.countsDown = event.countsDown
        context.insert(copy)
        let key = CalendarMath.dayKey(day)
        if !event.skippedDays.contains(key) { event.skippedDays.append(key) }
        didSave(copy, getReady: getReady, in: context)
        return copy
    }

    /// Shifts a Sunday-first weekday mask by a number of days.
    static func rotate(_ mask: Int, by days: Int) -> Int {
        let shift = ((days % 7) + 7) % 7
        var result = 0
        for bit in 0..<7 where mask & (1 << bit) != 0 {
            result |= 1 << ((bit + shift) % 7)
        }
        return result
    }

    /// A kid ticking a "bring" item off (or back on) for one day.
    static func togglePacked(_ item: String, event eventID: UUID, kid memberID: UUID, day: Date, in context: ModelContext) {
        let start = Calendar.current.startOfDay(for: day)
        let event: UUID? = eventID
        let member: UUID? = memberID
        let all = (try? context.fetch(FetchDescriptor<EventPacking>(predicate: #Predicate { $0.eventID == event && $0.memberID == member }))) ?? []
        let packing: EventPacking
        if let existing = all.first(where: { Calendar.current.isDate($0.day, inSameDayAs: start) }) {
            packing = existing
        } else {
            packing = EventPacking(eventID: eventID, memberID: memberID, day: start)
            context.insert(packing)
        }
        var packed = packing.packed
        if packed.contains(item) { packed.remove(item) } else { packed.insert(item) }
        packing.packed = packed
        Persistence.save(context)
    }

    /// The get-ready chore: "Get ready for <event>" for the kids going, the night before each
    /// time it happens. Works for one-time, daily and weekly events.
    private static func syncGetReadyChore(for event: FamilyEvent, on: Bool, points: Int, in context: ModelContext) {
        let existing = Self.chore(event.getReadyChoreID, in: context)
        let kids = Persistence.fetchAll(Member.self, in: context).filter { $0.isKid && !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
        let going = event.attendeeIDs.isEmpty ? kids.map(\.id) : kids.map(\.id).filter { event.attendeeIDs.contains($0) }
        guard on, !event.isArchived, !going.isEmpty, supportsGetReady(event.repeatRule) else {
            existing?.isArchived = true
            if !on { event.getReadyChoreID = nil }
            return
        }
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: event.start)
        let nightBefore = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        let chore: Chore
        if let existing {
            chore = existing
        } else {
            chore = Chore(title: "", symbol: "backpack", points: points, sortOrder: -1)
            chore.eventID = event.id
            context.insert(chore)
            event.getReadyChoreID = chore.id
        }
        chore.isArchived = false
        chore.title = "Get ready for \(event.title)"
        chore.assigneeIDs = going
        chore.requiresApproval = false
        switch event.repeatRule {
        case .never:
            chore.repeatRule = .once
            chore.startDate = nightBefore
        case .daily:
            chore.repeatRule = .daily
            chore.startDate = nightBefore
        default:
            let mask = event.weekdayMask == 0 ? ChoreMath.bit(forWeekday: calendar.component(.weekday, from: firstDay)) : event.weekdayMask
            chore.repeatRule = .someDays
            chore.weekdayMask = CalendarMath.nightBefore(mask: mask)
            chore.startDate = nightBefore
        }
    }

    static func supportsGetReady(_ rule: EventRepeat) -> Bool {
        rule == .never || rule == .daily || rule == .weekly
    }

    static func event(_ id: UUID?, in context: ModelContext) -> FamilyEvent? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<FamilyEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
