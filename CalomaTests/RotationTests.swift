import Foundation
import Testing
@testable import Caloma

/// Rotations: whose turn it is, through skips, swaps and pauses.
struct RotationTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 1
        return calendar
    }()

    let ella = UUID()
    let max = UUID()
    let ava = UUID()
    var three: [UUID] { [ella, max, ava] }

    /// Noon on a day in 2026 (October by default). October 4th is a Sunday.
    func day(_ day: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func rule(_ period: RotationPeriod, mode: RotationMode = .turns, weekday: Int = 0, anchor: Date? = nil, adjustments: RotationAdjustments = RotationAdjustments()) -> RotationRule {
        RotationRule(mode: mode, period: period, weekday: weekday, anchor: anchor ?? calendar.startOfDay(for: day(4)), adjustments: adjustments)
    }

    func who(_ rule: RotationRule, on date: Date, slot: Int = 0, members: [UUID]? = nil) -> [UUID] {
        RotationMath.assignees(slot: slot, on: date, members: members ?? three, rule: rule, calendar: calendar)
    }

    // MARK: Periods

    @Test func dailyRotationMovesOnEveryDay() {
        let daily = rule(.day)
        #expect(who(daily, on: day(4)) == [ella])
        #expect(who(daily, on: day(5)) == [max])
        #expect(who(daily, on: day(6)) == [ava])
        #expect(who(daily, on: day(7)) == [ella])
        #expect(who(daily, on: day(3)) == [ava])
    }

    @Test func weeklyRotationMovesOnEachSunday() {
        let weekly = rule(.week)
        #expect(who(weekly, on: day(4)) == [ella])
        #expect(who(weekly, on: day(10)) == [ella])
        #expect(who(weekly, on: day(11)) == [max])
        #expect(who(weekly, on: day(18)) == [ava])
        #expect(who(weekly, on: day(25)) == [ella])
    }

    @Test func weeklyRotationCanSwitchOnAnotherDay() {
        // Switching Wednesdays, starting Tuesday the 13th: that turn ends the next day.
        let weekly = rule(.week, weekday: 4, anchor: day(13))
        #expect(RotationMath.periodIndex(of: day(13), rule: weekly, calendar: calendar) == 0)
        #expect(RotationMath.periodIndex(of: day(14), rule: weekly, calendar: calendar) == 1)
        #expect(RotationMath.periodIndex(of: day(20), rule: weekly, calendar: calendar) == 1)
        #expect(RotationMath.periodIndex(of: day(21), rule: weekly, calendar: calendar) == 2)
        #expect(calendar.component(.weekday, from: RotationMath.start(ofPeriod: 1, rule: weekly, calendar: calendar)) == 4)
    }

    @Test func twoWeekTurnsLastFourteenDays() {
        let biweekly = rule(.twoWeeks)
        #expect(who(biweekly, on: day(4)) == [ella])
        #expect(who(biweekly, on: day(17)) == [ella])
        #expect(who(biweekly, on: day(18)) == [max])
        #expect(who(biweekly, on: day(31)) == [max])
        #expect(who(biweekly, on: day(1, month: 11)) == [ava])
        // The fortnight before the start belongs to the last person.
        #expect(who(biweekly, on: day(3)) == [ava])
        #expect(RotationMath.end(ofPeriod: 0, rule: biweekly, calendar: calendar) == calendar.startOfDay(for: day(17)))
    }

    @Test func monthlyRotationMovesOnTheFirst() {
        let monthly = rule(.month, anchor: day(10))
        #expect(who(monthly, on: day(31)) == [ella])
        #expect(who(monthly, on: day(1, month: 11)) == [max])
        #expect(who(monthly, on: day(1, month: 12)) == [ava])
        #expect(who(monthly, on: day(30, month: 9)) == [ava])
        #expect(RotationMath.start(ofPeriod: 1, rule: monthly, calendar: calendar) == calendar.startOfDay(for: day(1, month: 11)))
    }

    @Test func weeksCountRightAcrossTheClockChange() {
        // Daylight saving ends November 1st in Denver.
        let weekly = rule(.week)
        #expect(RotationMath.periodIndex(of: day(8, month: 11), rule: weekly, calendar: calendar) == 5)
        #expect(RotationMath.periodIndex(of: day(7, month: 11), rule: weekly, calendar: calendar) == 4)
    }

    // MARK: Modes

    @Test func splitItUpGivesEachPersonADifferentChoreAndMovesThemTogether() {
        let split = rule(.week, mode: .split)
        #expect((0..<3).map { who(split, on: day(4), slot: $0) } == [[ella], [max], [ava]])
        #expect((0..<3).map { who(split, on: day(11), slot: $0) } == [[max], [ava], [ella]])
        // More chores than people: they wrap around.
        #expect(who(split, on: day(4), slot: 3) == [ella])
    }

    @Test func everyoneDoesItMeansEveryone() {
        #expect(who(rule(.week, mode: .everyone), on: day(11)) == three)
    }

    // MARK: Changing the line

    @Test func skippingWithoutMakeUpMovesEveryoneUp() {
        // Max is away the week of the 11th: Ava goes, then it carries on from her.
        let skipped = RotationMath.skipping(1, makeUp: false, adjustments: RotationAdjustments())
        let weekly = rule(.week, adjustments: skipped)
        #expect(who(weekly, on: day(4)) == [ella])
        #expect(who(weekly, on: day(11)) == [ava])
        #expect(who(weekly, on: day(18)) == [ella])
        #expect(who(weekly, on: day(25)) == [max])
    }

    @Test func skippingWithMakeUpTradesWithTheNextPerson() {
        let skipped = RotationMath.skipping(1, makeUp: true, adjustments: RotationAdjustments())
        let weekly = rule(.week, adjustments: skipped)
        #expect(who(weekly, on: day(11)) == [ava])
        #expect(who(weekly, on: day(18)) == [max])
        #expect(who(weekly, on: day(25)) == [ella])
    }

    @Test func aTradedTurnCantBeSkippedUntilTheTradeIsUndone() {
        // Max skips the week of the 11th, trading with Ava, so he has the week of the 18th.
        let traded = RotationMath.skipping(1, makeUp: true, adjustments: RotationAdjustments())
        #expect(RotationMath.skipping(2, makeUp: true, adjustments: traded) == traded)
        #expect(RotationMath.skipping(2, makeUp: false, adjustments: traded) == traded)
        #expect(who(rule(.week, adjustments: traded), on: day(18)) == [max])
    }

    @Test func swapsNextToAPauseOrAnotherSwapAreRefused() {
        let paused = RotationMath.pausing(2, adjustments: RotationAdjustments())
        #expect(!RotationMath.canSwap(1, adjustments: paused))
        #expect(RotationMath.swapping(1, adjustments: paused).swaps.isEmpty)
        let swapped = RotationMath.swapping(1, adjustments: RotationAdjustments())
        #expect(RotationMath.swapping(2, adjustments: swapped).swaps == [1])
        // Skipping with make-up next to a pause moves everyone up instead.
        #expect(RotationMath.skipping(1, makeUp: true, adjustments: paused).shifts == [1])
    }

    @Test func trimmingKeepsPausesSoTheLineDoesntMove() {
        var adjustments = RotationMath.pausing(1, adjustments: RotationAdjustments())
        adjustments.swaps = [2]
        let trimmed = adjustments.trimmed(before: 20)
        #expect(trimmed.pauses == [1])
        #expect(trimmed.swaps.isEmpty)
    }

    @Test func swappingTwiceUndoesIt() {
        let once = RotationMath.swapping(2, adjustments: RotationAdjustments())
        #expect(once.swaps == [2])
        #expect(RotationMath.swapping(2, adjustments: once).isEmpty)
    }

    @Test func pausingLeavesTheTurnEmptyAndTheLineWaits() {
        let paused = RotationMath.pausing(1, adjustments: RotationAdjustments())
        let weekly = rule(.week, adjustments: paused)
        #expect(who(weekly, on: day(11)).isEmpty)
        #expect(who(weekly, on: day(18)) == [max])
        #expect(who(weekly, on: day(25)) == [ava])
        // A paused turn has nobody, split up or not.
        #expect(who(rule(.week, mode: .split, adjustments: paused), on: day(11), slot: 2).isEmpty)
    }

    @Test func adjustmentsRoundTripThroughText() {
        var adjustments = RotationAdjustments()
        adjustments.shifts = [3, -1]
        adjustments.swaps = [5]
        adjustments.pauses = [7]
        #expect(adjustments.raw == "shift:-1,shift:3,swap:5,pause:7")
        #expect(RotationAdjustments(raw: adjustments.raw) == adjustments)
        #expect(RotationAdjustments(raw: "nonsense,swap:x,pause:2").pauses == [2])
    }

    // MARK: Fair shares

    @Test func turnCountsShowWhoHasHadMore() {
        let plain = RotationMath.turnCounts(from: 0, through: 5, members: three, adjustments: RotationAdjustments())
        #expect(plain == [ella: 2, max: 2, ava: 2])
        let skipped = RotationMath.turnCounts(from: 0, through: 5, members: three, adjustments: RotationMath.skipping(1, makeUp: false, adjustments: RotationAdjustments()))
        #expect(skipped[max] == 1)
        #expect(skipped[ella] == 3)
    }

    @Test func summaryFindsSomeonesNextTurn() {
        let summary = RotationSummary(id: UUID(), isGroup: true, name: "Kitchen", symbol: "fork.knife", colorHex: nil, members: three, rule: rule(.week), choreTitles: ["Dishes"])
        #expect(summary.holder(ofPeriod: 0) == ella)
        #expect(summary.nextTurn(of: ava, after: 0) == 2)
        #expect(summary.nextTurn(of: ella, after: 0) == 3)
        #expect(summary.nextTurn(of: UUID(), after: 0) == nil)
    }

    // MARK: Through ChoreMath

    @Test func oldTakeTurnsChoresStillSwapWeeklyFromTheirStart() {
        var shared = ChoreRecord(title: "Dishes", assigneeIDs: [ella, max], repeatRule: .daily, startDate: calendar.startOfDay(for: day(4)))
        shared.rotates = true
        #expect(ChoreMath.assignees(of: shared, on: day(6), calendar: calendar) == [ella])
        #expect(ChoreMath.assignees(of: shared, on: day(13), calendar: calendar) == [max])
    }

    @Test func choresInASplitGroupLandOnDifferentPeople() {
        func chore(_ slot: Int) -> ChoreRecord {
            var record = ChoreRecord(title: "Chore \(slot)", assigneeIDs: three, repeatRule: .daily, startDate: calendar.startOfDay(for: day(1)))
            record.rotates = true
            record.rotationMode = .split
            record.rotationPeriod = .day
            record.rotationAnchor = calendar.startOfDay(for: day(13))
            record.rotationSlot = slot
            return record
        }
        let chores = (0..<3).map(chore)
        let items = ChoreMath.items(on: day(14), chores: chores, completions: [], calendar: calendar)
        #expect(items.count == 3)
        #expect(Set(items.compactMap(\.memberID)) == Set(three))
        #expect(items.first { $0.chore.rotationSlot == 0 }?.memberID == max)
    }
}
