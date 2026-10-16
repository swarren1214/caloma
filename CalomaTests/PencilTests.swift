import Foundation
import SwiftData
import Testing
@testable import Caloma

/// Reading a handwritten "when", and which wall notes show for whom.
@MainActor
struct PencilTests {
    let calendar = Calendar.current
    /// Thursday, October 15, 2026, mid-morning.
    var now: Date { date(15, 10) }

    func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func parse(_ text: String, day: Int = 15) -> EventTimeParser.Result? {
        EventTimeParser.parse(text, day: date(day), now: now, calendar: calendar)
    }

    @Test func weekdayAndAfternoonTime() {
        let result = parse("Tue 4:30")
        #expect(result?.start == date(20, 16, 30))
        #expect(result?.end == date(20, 17, 30))
        #expect(result?.isAllDay == false)
    }

    @Test func tomorrowWithABareHour() {
        #expect(parse("tmrw 6")?.start == date(16, 18))
    }

    @Test func ranges() {
        #expect(parse("Sat 10-12")?.start == date(17, 10))
        #expect(parse("Sat 10-12")?.end == date(17, 12))
        #expect(parse("4-6pm")?.start == date(15, 16))
        #expect(parse("4-6pm")?.end == date(15, 18))
        #expect(parse("10–12pm")?.start == date(15, 10))
        #expect(parse("10–12pm")?.end == date(15, 12))
    }

    @Test func misreadsAndMissingColons() {
        #expect(parse("4:3O")?.start == date(15, 16, 30))
        #expect(parse("430")?.start == date(15, 16, 30))
        #expect(parse("noon")?.start == date(15, 12))
        #expect(parse("9 a.m.")?.start == date(15, 9))
    }

    @Test func writtenDates() {
        #expect(parse("10/20 9am")?.start == date(20, 9))
        #expect(parse("Oct 22 7pm")?.start == date(22, 19))
    }

    @Test func aDayAloneIsAllDay() {
        let result = parse("Saturday")
        #expect(result?.isAllDay == true)
        #expect(result?.start == date(17))
        #expect(result?.end == date(18))
        // Today's weekday is today, not next week.
        #expect(parse("Thursday")?.start == date(15))
    }

    @Test func usesTheSheetsDayWhenNoneIsWritten() {
        #expect(parse("7:15", day: 19)?.start == date(19, 19, 15))
    }

    @Test func tonightIsTheEvening() {
        #expect(parse("tonight 8")?.start == date(15, 20))
    }

    @Test func aNameIsNotTomorrow() {
        #expect(parse("Tom 4pm")?.start == date(15, 16))
    }

    @Test func wordsThatAreNotTimes() {
        #expect(parse("Soccer") == nil)
        #expect(parse("monthly wedding") == nil)
    }

    /// Notes live in a store, as they do in the app.
    func note(for people: [UUID], keep: WallNoteKeep) -> WallNote {
        let note = WallNote(drawing: Data(), from: nil, audience: people, keep: keep, now: now)
        context.insert(note)
        return note
    }

    let container = Persistence.makeContainer(inMemory: true)
    var context: ModelContext { container.mainContext }

    @Test func wallNotesShowForTheirAudience() {
        let ella = UUID(), max = UUID()
        let once = note(for: [ella], keep: .once)
        #expect(WallNoteQueue.isPending(once, for: ella, now: now))
        #expect(!WallNoteQueue.isPending(once, for: max, now: now))
        once.seenBy.append(ella)
        #expect(!WallNoteQueue.isPending(once, for: ella, now: now))
        #expect(WallNoteQueue.isFinished(once, now: now))
    }

    @Test func todayNotesEndAtMidnight() {
        let ella = UUID()
        let today = note(for: [ella], keep: .today)
        today.seenBy.append(ella)
        // Still shows on later visits today.
        #expect(WallNoteQueue.isPending(today, for: ella, now: date(15, 20)))
        #expect(!WallNoteQueue.isPending(today, for: ella, now: date(16, 7)))
        #expect(WallNoteQueue.isFinished(today, now: date(16, 7)))
    }

    @Test func untilErasedKeepsShowing() {
        let ella = UUID()
        let kept = note(for: [ella], keep: .untilErased)
        kept.seenBy.append(ella)
        #expect(WallNoteQueue.isPending(kept, for: ella, now: date(30)))
        #expect(!WallNoteQueue.isFinished(kept, now: date(30)))
    }
}
