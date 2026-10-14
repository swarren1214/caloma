import Foundation
import Testing
@testable import Caloma

/// The family calendar's arithmetic: repeats, days, countdowns.
struct CalendarMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 1
        return calendar
    }()

    let ella = UUID()
    let max = UUID()

    /// A time on a day in October 2026. The 13th is a Tuesday.
    func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func event(_ title: String = "Event", day: Int, hour: Int = 16, minutes: Int = 60, rule: EventRepeat = .never, mask: Int = 0, who: [UUID] = [], allDay: Bool = false) -> EventRecord {
        let start = allDay ? calendar.startOfDay(for: date(day)) : date(day, hour)
        let end = allDay ? calendar.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(Double(minutes) * 60)
        return EventRecord(title: title, start: start, end: end, isAllDay: allDay, attendeeIDs: who, repeatRule: rule, weekdayMask: mask)
    }

    @Test func oneTimeEventsHappenOnTheirDayOnly() {
        let dentist = event(day: 14)
        #expect(!CalendarMath.happens(dentist, on: date(13), calendar: calendar))
        #expect(CalendarMath.happens(dentist, on: date(14), calendar: calendar))
        #expect(!CalendarMath.happens(dentist, on: date(15), calendar: calendar))
    }

    @Test func weeklyEventsUseTheirDaysOrTheStartDay() {
        let tueThu = ChoreMath.bit(forWeekday: 3) | ChoreMath.bit(forWeekday: 5)
        let soccer = event(day: 13, rule: .weekly, mask: tueThu)
        #expect(CalendarMath.happens(soccer, on: date(15), calendar: calendar)) // Thursday
        #expect(!CalendarMath.happens(soccer, on: date(16), calendar: calendar)) // Friday
        #expect(CalendarMath.happens(soccer, on: date(20), calendar: calendar)) // next Tuesday
        let piano = event(day: 13, rule: .weekly)
        #expect(CalendarMath.happens(piano, on: date(20), calendar: calendar))
        #expect(!CalendarMath.happens(piano, on: date(21), calendar: calendar))
    }

    @Test func monthlyAndYearlyEventsKeepTheirDate() {
        let club = event(day: 9, rule: .monthly)
        #expect(CalendarMath.happens(club, on: date(9, month: 11), calendar: calendar))
        #expect(!CalendarMath.happens(club, on: date(10, month: 11), calendar: calendar))
        let birthday = event(day: 24, rule: .yearly, allDay: true)
        #expect(CalendarMath.happens(birthday, on: calendar.date(byAdding: .year, value: 1, to: date(24))!, calendar: calendar))
        #expect(!CalendarMath.happens(birthday, on: date(24, month: 11), calendar: calendar))
    }

    @Test func repeatsStopAtTheEndDateAndSkipSkippedDays() {
        var practice = event(day: 13, rule: .daily)
        practice.repeatEnd = date(16)
        practice.skippedDays = [CalendarMath.dayKey(date(15), calendar: calendar)]
        let days = (13...18).filter { CalendarMath.happens(practice, on: date($0), calendar: calendar) }
        #expect(days == [13, 14, 16])
    }

    @Test func occurrencesKeepTheTimeOfDayAndLength() {
        let soccer = event(day: 13, hour: 16, minutes: 75, rule: .weekly)
        let next = CalendarMath.occurrences(of: [soccer], on: date(20), calendar: calendar)
        #expect(next.count == 1)
        #expect(next.first?.start == date(20, 16))
        #expect(next.first?.end == date(20, 17, 15))
    }

    @Test func allDayEventsComeFirstAndMultiDayEventsCoverEachDay() {
        var trip = event("Trip", day: 21, allDay: true)
        trip.end = calendar.startOfDay(for: date(23)) // the 21st and 22nd
        let game = event("Game", day: 22, hour: 9)
        #expect(CalendarMath.occurrences(of: [trip], on: date(22), calendar: calendar).count == 1)
        #expect(CalendarMath.occurrences(of: [trip], on: date(23), calendar: calendar).isEmpty)
        #expect(CalendarMath.occurrences(of: [game, trip], on: date(22), calendar: calendar).map(\.event.title) == ["Trip", "Game"])
    }

    @Test func countdownsFindTheNextOneForTheKid() {
        var movie = event("Movie night", day: 16, hour: 19, who: [max])
        movie.countsDown = true
        var party = event("Party", day: 24, hour: 14, who: [])
        party.countsDown = true
        let now = date(13, 15)
        #expect(CalendarMath.nextCountdown([movie, party], for: max, now: now, calendar: calendar)?.event.title == "Movie night")
        #expect(CalendarMath.nextCountdown([movie, party], for: ella, now: now, calendar: calendar)?.event.title == "Party")
        #expect(CalendarMath.sleeps(from: now, until: date(16, 19), calendar: calendar) == 3)
    }

    @Test func monthGridsAreWholeWeeks() {
        let grid = CalendarMath.monthGrid(for: date(13), calendar: calendar)
        #expect(grid.count == 35) // Sep 27 – Oct 31, 2026
        #expect(calendar.component(.day, from: grid.first!) == 27)
        #expect(calendar.component(.day, from: grid.last!) == 31)
    }

    @Test func theNightBeforeWrapsAroundTheWeek() {
        let sundayAndTuesday = ChoreMath.bit(forWeekday: 1) | ChoreMath.bit(forWeekday: 3)
        let saturdayAndMonday = ChoreMath.bit(forWeekday: 7) | ChoreMath.bit(forWeekday: 2)
        #expect(CalendarMath.nightBefore(mask: sundayAndTuesday) == saturdayAndMonday)
    }
}
