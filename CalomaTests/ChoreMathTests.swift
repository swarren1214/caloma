import Foundation
import Testing
@testable import Caloma

/// The family's arithmetic. Every board, balance and due date in the app comes from these.
struct ChoreMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 1
        return calendar
    }()

    let ella = UUID()
    let max = UUID()

    /// Noon on a day in October 2026. The 13th is a Tuesday.
    func day(_ day: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func chore(_ rule: ChoreRepeat = .daily, kids: [UUID]? = nil, mask: Int = 0, start: Int = 1, points: Int = 5) -> ChoreRecord {
        ChoreRecord(title: "Chore", points: points, assigneeIDs: kids ?? [ella], repeatRule: rule, weekdayMask: mask, startDate: calendar.startOfDay(for: day(start)))
    }

    // MARK: Schedules

    @Test func dailyChoresComeUpEveryDayFromTheirStart() {
        let daily = chore(.daily, start: 5)
        #expect(!ChoreMath.occurs(daily, on: day(4), calendar: calendar))
        #expect(ChoreMath.occurs(daily, on: day(5), calendar: calendar))
        #expect(ChoreMath.occurs(daily, on: day(20), calendar: calendar))
    }

    @Test func weekdayChoresSkipTheWeekend() {
        let weekdays = chore(.weekdays)
        #expect(ChoreMath.occurs(weekdays, on: day(13), calendar: calendar)) // Tuesday
        #expect(!ChoreMath.occurs(weekdays, on: day(17), calendar: calendar)) // Saturday
        #expect(!ChoreMath.occurs(weekdays, on: day(18), calendar: calendar)) // Sunday
    }

    @Test func someDaysChoresComeUpOnTheirDays() {
        let tuesdayFriday = chore(.someDays, mask: ChoreMath.bit(forWeekday: 3) | ChoreMath.bit(forWeekday: 6))
        #expect(ChoreMath.occurs(tuesdayFriday, on: day(13), calendar: calendar))
        #expect(ChoreMath.occurs(tuesdayFriday, on: day(16), calendar: calendar))
        #expect(!ChoreMath.occurs(tuesdayFriday, on: day(14), calendar: calendar))
    }

    @Test func archivedChoresNeverComeUp() {
        var archived = chore(.daily)
        archived.isArchived = true
        #expect(!ChoreMath.occurs(archived, on: day(13), calendar: calendar))
        #expect(ChoreMath.items(on: day(13), chores: [archived], completions: [], calendar: calendar).isEmpty)
    }

    // MARK: Who does what

    @Test func takingTurnsSwapsKidsEachWeek() {
        var shared = chore(.daily, kids: [ella, max], start: 4) // Sunday the 4th
        shared.rotates = true
        #expect(ChoreMath.assignees(of: shared, on: day(6), calendar: calendar) == [ella])
        #expect(ChoreMath.assignees(of: shared, on: day(13), calendar: calendar) == [max])
        #expect(ChoreMath.assignees(of: shared, on: day(20), calendar: calendar) == [ella])
    }

    @Test func sharedChoresGiveEachKidTheirOwnLine() {
        let shared = chore(.daily, kids: [ella, max])
        let items = ChoreMath.items(on: day(13), chores: [shared], completions: [], calendar: calendar)
        #expect(items.count == 2)
        #expect(Set(items.compactMap(\.memberID)) == [ella, max])
    }

    @Test func upForGrabsIsOneLineUntilSomeoneClaimsIt() {
        var trash = chore(.daily, kids: [ella, max])
        trash.upForGrabs = true
        let open = ChoreMath.items(on: day(13), chores: [trash], completions: [], calendar: calendar)
        #expect(open.count == 1)
        #expect(open.first?.memberID == nil)

        let claim = CompletionRecord(choreID: trash.id, memberID: max, day: calendar.startOfDay(for: day(13)), status: .pending, points: 5)
        let claimed = ChoreMath.items(on: day(13), chores: [trash], completions: [claim], calendar: calendar)
        #expect(claimed.first?.memberID == max)
        #expect(claimed.first?.status == .pending)
        // Ella no longer sees it; Max does.
        #expect(ChoreMath.items(for: ella, on: day(13), chores: [trash], completions: [claim], calendar: calendar).isEmpty)
        #expect(ChoreMath.items(for: max, on: day(13), chores: [trash], completions: [claim], calendar: calendar).count == 1)
    }

    @Test func oneTimeChoresStayUntilDoneThenDropOff() {
        let once = chore(.once, start: 10)
        #expect(ChoreMath.items(on: day(9), chores: [once], completions: [], calendar: calendar).isEmpty)
        #expect(ChoreMath.items(on: day(12), chores: [once], completions: [], calendar: calendar).count == 1)

        let done = CompletionRecord(choreID: once.id, memberID: ella, day: calendar.startOfDay(for: day(10)), status: .approved, points: 5, completedAt: day(12))
        // Still showing (done) on the day it was finished, gone the next day.
        #expect(ChoreMath.items(on: day(12), chores: [once], completions: [done], calendar: calendar).first?.status == .approved)
        #expect(ChoreMath.items(on: day(13), chores: [once], completions: [done], calendar: calendar).isEmpty)
    }

    @Test func sentBackChoresAreOpenAgain() {
        let bed = chore(.daily)
        let back = CompletionRecord(choreID: bed.id, memberID: ella, day: calendar.startOfDay(for: day(13)), status: .sentBack, points: 5)
        let item = ChoreMath.items(on: day(13), chores: [bed], completions: [back], calendar: calendar).first
        #expect(item?.status == .open)
        #expect(item?.wasSentBack == true)
    }

    // MARK: Streaks

    @Test func streakCountsDaysWithEverythingDone() {
        let bed = chore(.daily, start: 1)
        let done = [10, 11, 12].map { CompletionRecord(choreID: bed.id, memberID: ella, day: calendar.startOfDay(for: day($0)), status: .approved, points: 5) }
        // Today (the 13th) isn't done yet, which doesn't break it.
        #expect(ChoreMath.streak(for: ella, through: day(13), chores: [bed], completions: done, calendar: calendar, maxDays: 30) == 3)
        let today = CompletionRecord(choreID: bed.id, memberID: ella, day: calendar.startOfDay(for: day(13)), status: .pending, points: 5)
        #expect(ChoreMath.streak(for: ella, through: day(13), chores: [bed], completions: done + [today], calendar: calendar, maxDays: 30) == 4)
    }

    @Test func daysWithNothingAssignedDontBreakAStreak() {
        let weekdays = chore(.weekdays, start: 1)
        // Friday the 9th and Monday the 12th done; the weekend had nothing.
        let done = [9, 12].map { CompletionRecord(choreID: weekdays.id, memberID: ella, day: calendar.startOfDay(for: day($0)), status: .approved, points: 5) }
        #expect(ChoreMath.streak(for: ella, through: day(13), chores: [weekdays], completions: done, calendar: calendar, maxDays: 30) == 2)
    }

    // MARK: Points

    @Test func balancesAddUpTheLedger() {
        let entries = [
            PointRecord(memberID: ella, points: 50, kind: .chore),
            PointRecord(memberID: ella, points: -40, kind: .reward),
            PointRecord(memberID: max, points: 30, kind: .chore),
        ]
        #expect(ChoreMath.balance(of: ella, entries: entries) == 10)
        #expect(ChoreMath.balance(of: max, entries: entries) == 30)
    }

    @Test func pendingRewardsAreSetAside() {
        let entries = [PointRecord(memberID: ella, points: 100)]
        let asked = RedemptionRecord(rewardID: UUID(), memberID: ella, cost: 40, status: .pending, requestedAt: day(13))
        #expect(ChoreMath.spendable(of: ella, entries: entries, redemptions: [asked]) == 60)
    }

    @Test func familyGoalProgressSumsContributions() {
        let goal = UUID()
        let entries = [
            PointRecord(memberID: ella, points: -30, kind: .goal, refID: goal),
            PointRecord(memberID: max, points: -20, kind: .goal, refID: goal),
            PointRecord(memberID: max, points: -20, kind: .reward),
        ]
        #expect(ChoreMath.goalProgress(goal, entries: entries) == 50)
        #expect(ChoreMath.goalShares(goal, entries: entries)[max] == 20)
    }

    // MARK: Rewards

    @Test func rewardsNeedEnoughPoints() {
        let check = RewardMath.check(cost: 60, limit: .none, eligible: true, spendable: 45, memberID: ella, rewardID: UUID(), redemptions: [], now: day(13), calendar: calendar)
        #expect(check == .needMore(15))
    }

    @Test func rewardLimitsCountThisPeriodOnly() {
        let screen = UUID()
        let monday = RedemptionRecord(rewardID: screen, memberID: ella, cost: 40, status: .approved, requestedAt: day(12))
        let lastWeek = RedemptionRecord(rewardID: screen, memberID: ella, cost: 40, status: .approved, requestedAt: day(6))
        let declined = RedemptionRecord(rewardID: screen, memberID: ella, cost: 40, status: .declined, requestedAt: day(13))
        let weekly = RewardMath.check(cost: 40, limit: .oncePerWeek, eligible: true, spendable: 100, memberID: ella, rewardID: screen, redemptions: [monday, lastWeek, declined], now: day(13), calendar: calendar)
        #expect(weekly == .limitReached)
        let twice = RewardMath.check(cost: 40, limit: .twicePerWeek, eligible: true, spendable: 100, memberID: ella, rewardID: screen, redemptions: [monday, lastWeek, declined], now: day(13), calendar: calendar)
        #expect(twice == .ok)
    }

    @Test func allowanceConvertsAndSplits() {
        #expect(RewardMath.cents(for: 250, centsPer100: 500) == 1250)
        let split = RewardMath.split(cents: 1250, spend: 70, save: 20, give: 10)
        #expect(split.save == 250)
        #expect(split.give == 125)
        #expect(split.spend + split.save + split.give == 1250)
    }

    // MARK: Home care

    @Test func homeCareDueStates() {
        #expect(HomeCareMath.due(day(10), now: day(13), calendar: calendar) == .overdue(days: 3))
        #expect(HomeCareMath.due(day(13), now: day(13), calendar: calendar) == .today)
        #expect(HomeCareMath.due(day(18), now: day(13), calendar: calendar) == .soon(days: 5))
        #expect(HomeCareMath.due(day(2, month: 12), now: day(13), calendar: calendar) == .later(days: 50))
    }

    @Test func nextDueCountsFromWhenItWasDone() {
        let next = HomeCareMath.nextDue(after: day(13), count: 90, unit: .days, calendar: calendar)
        #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: day(13)), to: next).day == 90)
        #expect(HomeCareMath.daysLate(due: day(10), doneAt: day(13), calendar: calendar) == 3)
        #expect(HomeCareMath.daysLate(due: day(20), doneAt: day(13), calendar: calendar) == 0)
    }

    @Test func intervalLabels() {
        #expect(HomeCareMath.intervalLabel(count: 1, unit: .months) == "Monthly")
        #expect(HomeCareMath.intervalLabel(count: 90, unit: .days) == "Every 90 days")
    }
}
