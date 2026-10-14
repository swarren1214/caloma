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
