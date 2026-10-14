import Foundation
import SwiftData
import Testing
@testable import Caloma

/// Drag to reschedule: one-time events, one day of a series, and a whole series.
@MainActor
struct EventMoveTests {
    let calendar = Calendar.current

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func events(in context: ModelContext) -> [FamilyEvent] {
        (try? context.fetch(FetchDescriptor<FamilyEvent>())) ?? []
    }

    @Test func rotatingWeekdays() {
        let tuesdayThursday = ChoreMath.bit(forWeekday: 3) | ChoreMath.bit(forWeekday: 5)
        let wednesdayFriday = ChoreMath.bit(forWeekday: 4) | ChoreMath.bit(forWeekday: 6)
        #expect(Family.rotate(tuesdayThursday, by: 1) == wednesdayFriday)
        #expect(Family.rotate(wednesdayFriday, by: -1) == tuesdayThursday)
        // Saturday wraps to Sunday.
        #expect(Family.rotate(ChoreMath.bit(forWeekday: 7), by: 1) == ChoreMath.bit(forWeekday: 1))
        #expect(Family.rotate(tuesdayThursday, by: 7) == tuesdayThursday)
    }

    @Test func movingAOneTimeEventKeepsItsLength() {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let dentist = FamilyEvent(title: "Dentist", start: date(15, 16), end: date(15, 17))
        context.insert(dentist)
        Family.move(dentist, from: calendar.startOfDay(for: date(15, 0)), to: date(16, 9, 30), allOccurrences: false, in: context)
        #expect(dentist.start == date(16, 9, 30))
        #expect(dentist.end == date(16, 10, 30))
        #expect(events(in: context).count == 1)
    }

    @Test func movingOneDayOfASeries() {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        // Soccer, Tuesdays 4:30–5:30, starting the 13th.
        let soccer = FamilyEvent(title: "Soccer", start: date(13, 16, 30), end: date(13, 17, 30))
        soccer.repeatRule = .weekly
        soccer.weekdayMask = ChoreMath.bit(forWeekday: 3)
        context.insert(soccer)
        let copy = Family.move(soccer, from: calendar.startOfDay(for: date(20, 0)), to: date(21, 16, 30), allOccurrences: false, in: context)
        #expect(soccer.skippedDays == [CalendarMath.dayKey(date(20, 0))])
        #expect(soccer.start == date(13, 16, 30))
        #expect(copy !== soccer)
        #expect(copy.repeatRule == .never)
        #expect(copy.start == date(21, 16, 30))
        #expect(copy.end == date(21, 17, 30))
        #expect(events(in: context).count == 2)
    }

    @Test func movingAWholeSeries() {
        let context = Persistence.makeContainer(inMemory: true).mainContext
        let soccer = FamilyEvent(title: "Soccer", start: date(13, 16, 30), end: date(13, 17, 30))
        soccer.repeatRule = .weekly
        soccer.weekdayMask = ChoreMath.bit(forWeekday: 3)
        soccer.repeatEnd = date(27, 0)
        context.insert(soccer)
        // Next week's Tuesday dragged to Wednesday at 5.
        Family.move(soccer, from: calendar.startOfDay(for: date(20, 0)), to: date(21, 17), allOccurrences: true, in: context)
        #expect(soccer.start == date(14, 17))
        #expect(soccer.end == date(14, 18))
        #expect(soccer.weekdayMask == ChoreMath.bit(forWeekday: 4))
        #expect(soccer.repeatEnd == date(28, 0))
        #expect(events(in: context).count == 1)
    }
}
